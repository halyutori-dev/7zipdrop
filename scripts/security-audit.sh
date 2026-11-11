#!/bin/bash
# Mechanical security / OSS-hygiene gate. Every claim in docs/SECURITY.md that can be
# checked by a machine is checked here, so it stays true instead of aging into prose.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

PINNED_SHA="1cf6760579502f87e591ff5c73a005ec50b3e4d6f507e8b038382d563c3175b9"
PINNED_VERSION="26.02"
TARBALL="vendor/download/7z2602-mac.tar.xz"
BINARY="vendor/ex/7zz"
APP="build/7Zip Drop.app"
SRC="Sources"

pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  SKIP  %s\n' "$1"; }

echo "=== 1. bundled OSS provenance ==="
if [ -f "${TARBALL}" ]; then
  actual="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
  [ "${actual}" = "${PINNED_SHA}" ] \
    && ok "7-Zip tarball SHA-256 matches the officially published digest" \
    || bad "7-Zip tarball SHA-256 mismatch (got ${actual})"
else
  skip "tarball not present (run scripts/fetch-7zz.sh); binary check still applies"
fi

if [ -x "${BINARY}" ]; then
  version="$("${BINARY}" i 2>/dev/null | head -2 | tr -d '\n')"
  case "${version}" in
    *"${PINNED_VERSION}"*) ok "bundled 7zz reports version ${PINNED_VERSION}" ;;
    *) bad "bundled 7zz is not ${PINNED_VERSION}: ${version}" ;;
  esac
  archs="$(lipo -archs "${BINARY}" 2>/dev/null)"
  case "${archs}" in
    *x86_64*arm64*|*arm64*x86_64*) ok "bundled 7zz is a universal binary (${archs})" ;;
    *) bad "bundled 7zz is not universal (${archs})" ;;
  esac
else
  bad "bundled 7zz missing at ${BINARY}"
fi

# The pinned digest must be identical everywhere it is written down.
for f in scripts/fetch-7zz.sh NOTICE.md docs/VERIFIED-7ZIP-CONTRACT.md; do
  grep -q "${PINNED_SHA}" "$f" \
    && ok "pinned digest recorded in $f" \
    || bad "pinned digest missing or stale in $f"
done

echo
echo "=== 2. known vulnerabilities in the bundled version ==="
# Recorded as data so a future auditor sees what was checked and when.
while IFS='|' read -r cve note; do
  [ -z "${cve}" ] && continue
  grep -q "${cve}" docs/SECURITY.md \
    && ok "${cve} assessed in docs/SECURITY.md (${note})" \
    || bad "${cve} not assessed in docs/SECURITY.md"
done <<'CVES'
CVE-2026-48095|NTFS handler heap overflow, fixed in 26.01
CVE-2026-14266|XZ heap overflow, fixed in 26.02
CVE-2026-58052|Windows Mark-of-the-Web bypass, extraction-side
CVES

grep -q '展開' docs/SECURITY.md \
  && ok "docs/SECURITY.md discusses the extraction-side attack surface" \
  || bad "docs/SECURITY.md still describes a creation-only app"

echo
echo "=== 3. supply chain ==="
if grep -qE '\.package\(' Package.swift; then
  bad "Package.swift pulls in external Swift dependencies"
else
  ok "zero external Swift package dependencies (Apple frameworks + bundled 7zz only)"
fi

echo
echo "=== 4. no network access from this app ==="
if grep -rInE 'URLSession|NSURLConnection|Network\.framework|CFSocket|socket\(|getaddrinfo|NWConnection' "${SRC}" >/dev/null; then
  bad "networking API referenced in ${SRC}"
  grep -rInE 'URLSession|NWConnection|socket\(' "${SRC}" | sed 's/^/        /'
else
  ok "no networking API anywhere in ${SRC}"
fi

echo
echo "=== 5. no shell is involved (so file names cannot inject commands) ==="
shell_hits="$(grep -rInE '/bin/sh|/bin/bash|(^|[^.[:alnum:]_])(system|popen)\(|"-c"' "${SRC}" \
  | grep -vE ':[0-9]+: *//' || true)"
if [ -n "${shell_hits}" ]; then
  bad "a shell may be spawned from ${SRC}"
  printf '%s\n' "${shell_hits}" | sed 's/^/        /'
else
  ok "7zz is exec'd directly with an argument vector; no shell interpolation"
fi

echo
echo "=== 6. argument-injection defences are wired ==="
# Anchored to the add path specifically: the t command also passes -spd, so a bare
# grep for the switch would stay green even if the add path lost it.
grep -qE 'arguments \+= \["-spd", "-ssp"' "${SRC}/CompressorCore/SevenZipInvocation.swift" \
  && ok "-spd present on the add path: dropped names are never glob-expanded" \
  || bad "-spd missing from the add path: a file named 'x*' could pull in unrelated files"
grep -q 'arguments.append("--")' "${SRC}/CompressorCore/SevenZipInvocation.swift" \
  && ok "-- present: names starting with - or @ stay names" \
  || bad "-- missing: a file named '-foo' would be parsed as a switch"

echo
echo "=== 7. secret handling ==="
grep -q 'arguments.append("-p")' "${SRC}/CompressorCore/SevenZipInvocation.swift" \
  && ok "the add command passes a bare -p and answers the prompt on stdin" \
  || bad "the add command may be putting the password in argv"
grep -q 'F_SETNOSIGPIPE' "${SRC}/CompressorCore/SevenZipRunner.swift" \
  && ok "writing the password to a 7zz that already exited fails with EPIPE instead of killing the app (SIGPIPE)" \
  || bad "the stdin write can raise SIGPIPE and terminate the app"
grep -q '"-p\*\*\*\*\*\*\*\*"' "${SRC}/CompressorCore/SevenZipInvocation.swift" \
  && ok "any -p<secret> argument is masked before being shown or logged" \
  || bad "password redaction for displayed command lines is missing"
# The Bool flag recording *whether* a shared password exists is not the password.
persist_hits="$(grep -rInE '(defaults|UserDefaults[^)]*)\.set\([^)]*[Pp]assword' "${SRC}" \
  | grep -vE ':[0-9]+: *//' \
  | grep -vF 'defaults.set(hasPassword, forKey: hasSharedPasswordKey)' || true)"
if [ -n "${persist_hits}" ]; then
  bad "a password may be written to UserDefaults"
  printf '%s\n' "${persist_hits}" | sed 's/^/        /'
else
  ok "no code path writes a password to UserDefaults"
fi
# The persisted settings type must not even have a field for it.
if grep -qiE '[Pp]assword' "${SRC}/CompressorCore/CompressionSettings.swift" \
   && grep -iE '[Pp]assword' "${SRC}/CompressorCore/CompressionSettings.swift" | grep -qvE '^ *//|rememberPasswordInKeychain|verifyEncrypted'; then
  bad "CompressionSettings (which is what gets persisted) mentions a password field"
  grep -inE '[Pp]assword' "${SRC}/CompressorCore/CompressionSettings.swift" | sed 's/^/        /'
else
  ok "the persisted settings type carries no password, only the remember-in-keychain flag"
fi
grep -q 'kSecAttrAccessibleWhenUnlocked' "${SRC}/CompressorCore/PasswordStore.swift" \
  && ok "keychain entries require an unlocked device and are not iCloud-synced" \
  || bad "keychain accessibility class not pinned"
grep -q 'case containsNewline' "${SRC}/CompressorCore/Errors.swift" \
  && ok "passwords containing a newline are rejected up front (stdin channel is one line)" \
  || bad "newline validation for passwords is missing"

echo
echo "=== 8. this app never destroys user data ==="
if grep -rIn '"-sdel"' "${SRC}" >/dev/null; then
  bad "the -sdel switch (delete originals after compression) is reachable"
else
  ok "-sdel is never passed: source files are never deleted"
fi
# Every removeItem must target the staging directory or a staged file, never user input.
offenders="$(grep -rIn 'removeItem' "${SRC}" | grep -viE 'staging|source|iconset' || true)"
if [ -n "${offenders}" ]; then
  bad "a removeItem call targets something other than staging"
  printf '%s\n' "${offenders}" | sed 's/^/        /'
else
  ok "removeItem only ever targets the staging directory or a staged file"
fi
grep -q 'CompressorError.destinationExists' "${SRC}/CompressorCore/AtomicFileMover.swift" \
  && ok "the final move claims its name with link(2) and fails rather than overwriting" \
  || bad "the delivery step may overwrite an existing file"
grep -q '0o700' "${SRC}/CompressorCore/CompressionEngine.swift" \
  && ok "the staging directory (which may hold an encrypted archive) is created 0700" \
  || bad "staging directory permissions are not restricted"

echo
echo "=== 9. extraction defences (the side where 7-Zip's known RCEs live) ==="
E="${SRC}/CompressorCore/ExtractionEngine.swift"
L="${SRC}/CompressorCore/ArchiveListing.swift"
X="${SRC}/CompressorCore/ExtractionSettings.swift"

grep -q 'static func isSafePath' "$L" \
  && ok "entry paths are checked against an allowlist of safe shapes, not a blacklist" \
  || bad "the entry-path safety check is missing"
grep -q 'allowUnsafeEntryPaths' "$X" \
  && grep -q 'allowUnsafeEntryPaths: false' "$X" \
  && ok "archives with escaping entry paths are refused by default" \
  || bad "escaping entry paths are not refused by default"

# The gate must run BEFORE anything is written, so its call has to come first in the file.
gate_line="$(grep -n 'ExtractionSafety.check' "$E" | head -1 | cut -d: -f1)"
extract_line="$(grep -n 'SevenZipCommandBuilder.extract' "$E" | head -1 | cut -d: -f1)"
if [ -n "${gate_line}" ] && [ -n "${extract_line}" ] && [ "${gate_line}" -lt "${extract_line}" ]; then
  ok "the size/path safety gate runs before the first extract call (line ${gate_line} < ${extract_line})"
else
  bad "the safety gate does not clearly precede extraction (gate=${gate_line:-none} extract=${extract_line:-none})"
fi

# Counting *calls*, not the declaration: a grep for the name alone stays green even when
# every call site has been deleted. Both extraction paths (outer and inner) must check.
containment_calls="$(grep -c 'try assertNoSymlinkEscapes(in:' "$E" || true)"
if [ "${containment_calls:-0}" -ge 2 ]; then
  ok "extracted symlinks are checked on every extraction path (${containment_calls} call sites)"
else
  bad "the symlink containment check is not called on every extraction path (${containment_calls:-0} call sites)"
fi
grep -q 'notEnoughDiskSpace' "$X" && grep -q 'extractionTooLarge' "$X" \
  && ok "a declared expansion size beyond the ceiling or the free space is refused (zip bomb)" \
  || bad "the expansion-size gate is missing"
grep -q 'addingReportingOverflow' "$L" && grep -q 'Int64(text) ?? Int64.max' "$L" \
  && ok "declared sizes saturate at Int64.max: an absurd declaration is refused, never wrapped, trapped or read as 0" \
  || bad "declared sizes can overflow or be read as 0"
# Formats that do not declare a size (contract #42) are only bounded while extracting, so
# both extraction paths (outer and inner) must pass a budget.
budget_calls="$(grep -c 'budget: outputBudget(for:' "$E" || true)"
if [ "${budget_calls:-0}" -ge 2 ]; then
  ok "output the listing cannot bound is measured while 7zz runs, on every extraction path (${budget_calls} call sites)"
else
  bad "the extraction output watchdog is not wired on every extraction path (${budget_calls:-0} call sites)"
fi
if grep -q '"x", overwriteExisting ? "-aoa" : "-aos"' "${SRC}/CompressorCore/SevenZipInvocation.swift"; then
  ok "extraction always answers the overwrite question up front (-aos, or -aoa when asked), so no prompt can stall it"
else
  bad "the extract command does not pass -aos/-aoa; an existing file would open an interactive prompt"
fi
grep -q 'appendingPathComponent("content"' "$E" \
  && ok "extraction targets a fresh staging directory, so nothing of the user's is in reach" \
  || bad "extraction may write straight into the destination"
if grep -rIn '"-y"' "${SRC}" >/dev/null; then
  bad "-y (assume yes) is reachable; it would auto-answer overwrite prompts"
else
  ok "-y is never passed, so no destructive query is ever auto-confirmed"
fi
# Nothing may delete or rewrite the archive that was handed to us.
if grep -n 'removeItem' "$E" | grep -vq 'staging'; then
  bad "ExtractionEngine removes something other than its staging directory"
  grep -n 'removeItem' "$E" | sed 's/^/        /'
else
  ok "the archive being extracted is never modified or deleted"
fi

echo
echo "=== 9b. destructive options are opt-in and recoverable ==="
APPSRC="${SRC}/SevenZipCompressorApp"
GS="${SRC}/CompressorCore/AppSettings.swift"
CE="${SRC}/CompressorCore/CompressionEngine.swift"

grep -q 'deleteSourceAfterCompress: false' "$GS" \
  && ok "「圧縮後に元のファイルを削除」 is off by default" \
  || bad "the delete-after-compress setting is not off by default"
grep -q 'overwriteOnExtract: false' "$GS" \
  && ok "「展開時の同名ファイルの上書き」 is off by default" \
  || bad "the overwrite-on-extract setting is not off by default"
grep -q 'trashItem' "${SRC}/CompressorCore/SourceRemover.swift" \
  && ok "removals go to the Trash, so they can be undone" \
  || bad "SourceRemover does not use the Trash"
if grep -rIn 'removeItem' "${SRC}/CompressorCore/SourceRemover.swift" >/dev/null; then
  bad "SourceRemover deletes outright somewhere"
else
  ok "SourceRemover never unlinks anything itself"
fi
grep -q 'status == .success' "$CE" \
  && ok "originals are removed only after an unqualified success (a warning keeps them)" \
  || bad "the success precondition for removing originals is missing"

echo
echo "=== 9c. the keychain is never touched on the main thread ==="
AM="${APPSRC}/AppModel.swift"
init_body="$(awk '/^    init\(\) \{/{flag=1} flag{print} /^    \}/{if(flag){exit}}' "$AM")"
if printf '%s' "${init_body}" | grep -q 'keychain'; then
  bad "AppModel.init() touches the keychain — a blocking read there deadlocks the launch"
  printf '%s\n' "${init_body}" | grep -n 'keychain' | sed 's/^/        /'
else
  ok "AppModel.init() does not touch the keychain"
fi
# Every keychain call must sit inside a detached task.
bad_calls=0
while IFS=: read -r line _; do
  [ -z "${line}" ] && continue
  context="$(sed -n "$((line > 3 ? line - 3 : 1)),${line}p" "$AM")"
  printf '%s' "${context}" | grep -q 'Task.detached' || bad_calls=$((bad_calls + 1))
done <<< "$(grep -n 'keychain\.\(load\|save\|delete\)' "$AM" || true)"
if [ "${bad_calls}" -eq 0 ]; then
  ok "every keychain call is made from a detached task, off the main thread"
else
  bad "${bad_calls} keychain call(s) may run on the main thread"
fi
grep -q 'hasSharedPasswordKey' "$AM" \
  && ok "whether a shared password exists is a plain flag, so the UI needs no keychain read" \
  || bad "the has-a-password flag is missing; the UI would have to read the keychain"

echo
echo "=== 10. license compliance ==="
for f in NOTICE.md vendor/ex/License.txt; do
  [ -s "$f" ] && ok "present: $f" || bad "missing: $f"
done
grep -qi 'LGPL' NOTICE.md && ok "NOTICE.md states the GNU LGPL license" || bad "NOTICE.md does not state the license"
grep -q '7-zip.org' NOTICE.md && ok "NOTICE.md links to www.7-zip.org as the license requires" || bad "NOTICE.md lacks the required link"

echo
echo "=== 11. built app bundle ==="
if [ -d "${APP}" ]; then
  codesign --verify --deep --strict "${APP}" 2>/dev/null \
    && ok "app bundle signature verifies (ad-hoc)" \
    || bad "app bundle signature does not verify"
  [ -x "${APP}/Contents/Helpers/7zz" ] && ok "7zz is bundled inside the app" || bad "7zz not bundled"
  [ -s "${APP}/Contents/Resources/ThirdParty/7-Zip/License.txt" ] \
    && ok "the 7-Zip license ships inside the bundle" \
    || bad "the 7-Zip license is not in the bundle"
  # The icon is built from Resources/AppIcon-1024.png. iconutil re-encodes each slice, so
  # bytes cannot be compared with a fresh render; check instead that all ten slices are
  # present, that the largest is a full 1024 square, and that it is not the tiny
  # vector-ish placeholder the project shipped before the artwork existed.
  ICNS="${APP}/Contents/Resources/AppIcon.icns"
  if [ -s "${ICNS}" ]; then
    ICON_SLICES_DIR="$(mktemp -d)"
    if iconutil -c iconset "${ICNS}" -o "${ICON_SLICES_DIR}/AppIcon.iconset" 2>/dev/null; then
      n="$(ls "${ICON_SLICES_DIR}/AppIcon.iconset" | grep -c '\.png$' || true)"
      [ "${n}" -eq 10 ] && ok "the icon ships all 10 slices" || bad "the icon has ${n} slices, expected 10"
      big="${ICON_SLICES_DIR}/AppIcon.iconset/icon_512x512@2x.png"
      dims="$(sips -g pixelWidth -g pixelHeight "${big}" 2>/dev/null | awk '/pixel/ {printf "%s", $2}')"
      [ "${dims}" = "10241024" ] && ok "the largest slice is 1024x1024" \
        || bad "the largest icon slice is ${dims:-missing}, expected 1024x1024"
      bytes="$(wc -c < "${ICNS}" | tr -d ' ')"
      [ "${bytes}" -gt 500000 ] && ok "the icon carries the real artwork (${bytes} bytes)" \
        || bad "AppIcon.icns is only ${bytes} bytes; the artwork looks lost"
    else
      bad "AppIcon.icns cannot be read back by iconutil"
    fi
    rm -rf "${ICON_SLICES_DIR}"
  else
    bad "AppIcon.icns is missing from the bundle"
  fi
  if /usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSHandlerRank' "${APP}/Contents/Info.plist" 2>/dev/null | grep -q None; then
    ok "LSHandlerRank=None: accepts drops without hijacking any file association"
  else
    bad "LSHandlerRank is not None; the app may become a default file handler"
  fi
else
  skip "app bundle not built yet (run: make app)"
fi

echo
printf '=== %d passed, %d failed ===\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ] || exit 1
