#!/bin/bash
# Injects known defects one at a time and asserts the test suite turns RED for each.
# A suite that stays green under a mutation is not protecting that behaviour.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

failures=0

run_suite() {
  local out line
  out="$(swift test 2>&1)"
  line="$(grep -E "Test run with .* (passed|failed)" <<<"${out}" | tail -1)"
  # A mutation that crashes the test process (e.g. an unhandled SIGPIPE) never prints a
  # summary line; the suite still went red, so report it as a failure, not as unknown.
  if [ -z "${line}" ] && grep -q "unexpected signal code" <<<"${out}"; then
    line="failed (test process killed by a signal)"
  fi
  echo "${line}"
}

run_tooltip_gate() {
  if ./scripts/check-tooltips.sh >/dev/null 2>&1; then echo "passed"; else echo "failed"; fi
}

# gate: "suite" (default) = swift test, "tooltips" = scripts/check-tooltips.sh. The
# tooltip gate needs its own runner because the app target is an executable and its
# AppKit-level behaviour is not reachable from swift test.
mutate() {
  local label="$1" file="$2" expr="$3" gate="${4:-suite}"
  cp "${file}" "${file}.bak"
  perl -0pi -e "${expr}" "${file}"
  if diff -q "${file}" "${file}.bak" >/dev/null; then
    echo "  ?  NO-OP    ${label} (pattern did not match; update this check)"
    failures=$((failures + 1))
  else
    local out
    case "${gate}" in
      tooltips) out="$(run_tooltip_gate)" ;;
      *)        out="$(run_suite)" ;;
    esac
    case "${out}" in
      *failed*) echo "  ok CAUGHT   ${label}" ;;
      *passed*) echo "  !! MISSED   ${label}"; failures=$((failures + 1)) ;;
      *)        echo "  ?  UNKNOWN  ${label} (${out})"; failures=$((failures + 1)) ;;
    esac
  fi
  mv "${file}.bak" "${file}"
}

B=Sources/CompressorCore/SevenZipInvocation.swift
P=Sources/CompressorCore/SevenZipOutputParser.swift
N=Sources/CompressorCore/ArchiveNaming.swift
X=Sources/CompressorCore/SevenZipExitStatus.swift
V=Sources/CompressorCore/SplitSize.swift

echo "mutation check — every injected defect must turn the suite RED:"
mutate "drop -spd (dropped names would be glob-expanded)"        "$B" 's/"-spd", "-ssp"/"-ssp"/'
mutate "password into argv instead of stdin"                     "$B" 's/if password != nil \{ arguments\.append\("-p"\) \}/if let password { arguments.append("-p" + password.value) }/'
mutate "drop -mem=AES256 (zip falls back to ZipCrypto)"          "$B" 's/arguments\.append\("-mem=AES256"\)/()/'
mutate "drop -sse (unreadable files silently omitted)"           "$B" 's/if settings\.abortOnUnreadableFile \{ arguments\.append\("-sse"\) \}/if false { arguments.append("-sse") }/'
mutate "drop -snl (symlinks dereferenced)"                       "$B" 's/if settings\.storeSymlinksAsLinks \{ arguments\.append\("-snl"\) \}/if false { arguments.append("-snl") }/'
mutate "omit -- (leading-dash names become switches)"            "$B" 's/arguments\.append\("--"\)\n        arguments\.append\(archive\.path\)/arguments.append(archive.path)/'
mutate "stop redacting -p<secret> in shown commands"             "$B" 's/argument\.hasPrefix\("-p"\) && argument\.count > 2 \? "-p\*\*\*\*\*\*\*\*" : argument/argument/'
mutate "treat exit 1 (warning) as success"                       "$X" 's/public var isSuccess: Bool \{ self == \.success \}/public var isSuccess: Bool { self == .success || self == .warning }/'
mutate "never step aside on a name collision"                    "$N" 's/if !occupied \{ return url \}/if true { return url }/'
mutate "ignore volume parts when checking collisions"            "$N" 's/\|\| existing\.contains \{ \$0\.hasPrefix\(volumePrefix\) \}//'
mutate "parser: never flush the trailing token"                  "$P" 's/if let event = flushBuffer\(\) \{ return \[event\] \}/if false, let event = flushBuffer() { return [event] }/'
mutate "parser: stop treating backspace as a delimiter"          "$P" 's/= \[0x08, 0x0D, 0x0A\]/= [0x0D, 0x0A]/'
mutate "split sizes become 1000-based"                           "$V" 's/case \.kibibytes: 1024\n            case \.mebibytes: 1024 \* 1024\n            case \.gibibytes: 1024 \* 1024 \* 1024/case .kibibytes: 1000\n            case .mebibytes: 1000 * 1000\n            case .gibibytes: 1000 * 1000 * 1000/'
mutate "split parser silently accepts garbage"                   "$V" 's/guard !digits\.isEmpty else \{ throw SplitSizeError\.malformed\(text\) \}/if digits.isEmpty { return nil }/'

E=Sources/CompressorCore/ExtractionEngine.swift
L=Sources/CompressorCore/ArchiveListing.swift
XS=Sources/CompressorCore/ExtractionSettings.swift
M=Sources/CompressorCore/AtomicFileMover.swift
D=Sources/CompressorCore/SevenZipDiagnostics.swift

echo
echo "extraction defences:"
mutate "entry-path allowlist accepts everything"                 "$L" 's/guard !path\.isEmpty else \{ return false \}/if true { return true }/'
mutate "entry-path check rejects harmless \".\" components"        "$L" 's/if component\.isEmpty \|\| component == "\.\." \{ return false \}/if component.isEmpty || component == "." || component == ".." { return false }/'
mutate "skip the safety gate before extracting"                  "$E" 's/try ExtractionSafety\.check\(\n            listing, settings: request\.settings,\n            availableBytes: freeSpace\(destination\)\)//'
mutate "symlink containment check becomes a no-op"               "$E" 's/func assertNoSymlinkEscapes\(in root: URL\) throws \{/func assertNoSymlinkEscapes(in root: URL) throws { if true { return }/'
mutate "expansion-size ceiling ignored"                          "$XS" 's/guard total <= settings\.maximumTotalBytes else \{/if false {/'
mutate "free-space check ignored"                                "$XS" 's/guard total <= usable else \{/if false {/'
mutate "volume parts are not redirected to .001"                 "$E" 's/guard let first = ArchiveDetection\.firstVolume\(of: url\) else \{ return url \}/return url\n        guard let first = ArchiveDetection.firstVolume(of: url) else { return url }/'
mutate "declared total wraps around instead of saturating"       "$L" 's/total = overflow \? Int64\.max : sum/total = sum/'
mutate "a size beyond Int64 is read as 0"                        "$L" 's/return Int64\(text\) \?\? Int64\.max/return Int64(text) ?? 0/'
mutate "path-less single-stream blocks dropped again"             "$L" 's/                unnamedStreamSizes\.append\(declaredSize\(block\["Size"\]\)\)\n//'
mutate "output watchdog never armed"                             "$E" 's/guard listing\.hasUndeclaredSizes \|\| singleStream else \{ return nil \}/guard false else { return nil }/'
mutate "watchdog ignores the content-detected format"            "$E" 's/\n            \|\| listing\.format\.map\(Self\.singleStreamTypes\.contains\) == true//'
mutate "no final measurement once 7zz has exited"                "$E" 's/if violation == nil \{/if false {/'
mutate "single root folder gets wrapped a second time"           "$E" 's/            Self\.isDirectory\(child\) \|\| !settings\.guaranteeContainingFolder/            !settings.guaranteeContainingFolder/'
mutate "delivery overwrites instead of claiming exclusively"     "$M" 's/UInt32\(RENAME_EXCL\)/UInt32(0)/'
mutate "delivery uses link(2), refused in protected folders"      "$M" 's/    public func claim\(from source: URL, to destination: URL\) throws \{\n        try exclusiveRename\(from: source, to: destination\)\n    \}/    public func claim(from source: URL, to destination: URL) throws {\n        let r = source.withUnsafeFileSystemRepresentation { s in destination.withUnsafeFileSystemRepresentation { d in link(s!, d!) == 0 ? 0 : errno } }\n        if r != 0 { throw CompressorError.linkFailed(code: r, path: destination.path) }\n        try? FileManager.default.removeItem(at: source)\n    }/'
mutate "wrong password no longer distinguished"                  "$D" 's/if lowercased\.contains\("wrong password"\) \{/if false {/'
mutate "missing password no longer detected"                     "$D" 's/if lowercased\.contains\("enter password"\) \{/if false {/'

CS=Sources/CompressorCore/CompressionEngine.swift
AS=Sources/CompressorCore/AppSettings.swift

echo
echo "new destructive options:"
mutate "originals removed even when the setting is off"          "$CS" 's/guard settings\.deleteSourcesAfterSuccess, status == \.success else \{ return \(\[\], \[\]\) \}/guard status == .success else { return ([], []) }/'
mutate "originals removed despite a warning"                     "$CS" 's/guard settings\.deleteSourcesAfterSuccess, status == \.success else \{ return \(\[\], \[\]\) \}/guard settings.deleteSourcesAfterSuccess else { return ([], []) }/'
mutate "overwrite mode ignored (always steps aside)"             "$E" 's/if settings\.overwriteExisting \{\n            \/\/ Replace what is there, but move it to the Trash first so it is recoverable\./if false {\n            \/\/ Replace what is there, but move it to the Trash first so it is recoverable./'
mutate "overwrite replaces without moving the old one to Trash"  "$E" 's/            if probe\.fileExists\(at: target\) \{\n                _ = try remover\.remove\(target\)\n            \}//'
mutate "フォルダを作成して展開 polarity flipped"                   "$AS" 's/settings\.guaranteeContainingFolder = general\.createContainingFolder/settings.guaranteeContainingFolder = !general.createContainingFolder/'
mutate "empty size limit becomes zero instead of unlimited"       "$AS" 's/settings\.maximumTotalBytes = try general\.extractionSizeLimit\(\)\?\.byteCount \?\? Int64\.max/settings.maximumTotalBytes = try general.extractionSizeLimit()?.byteCount ?? 0/'


RN=Sources/CompressorCore/SevenZipRunner.swift
mutate "stdin write can raise SIGPIPE again"                     "$RN" 's/                _ = fcntl\(writer\.fileDescriptor, F_SETNOSIGPIPE, 1\)\n//'
mutate "read the pipe with FileHandle (only yields at EOF)"       "$RN" 's/Self\.stream\(from: reader\.fileDescriptor, to: onOutput\)/while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty { onOutput(chunk) }/'


SM=Sources/SevenZipCompressorApp/SettingsMetrics.swift
SR=Sources/SevenZipCompressorApp/SettingsRow.swift
SS=Sources/SevenZipCompressorApp/SettingsSidebar.swift
CV=Sources/SevenZipCompressorApp/ContentView.swift

echo
echo "settings pane layout:"
mutate "pane rows tightened back to 1.2's density"        "$SM" 's/rowVerticalInset: CGFloat = 13/rowVerticalInset: CGFloat = 9/'
mutate "a row re-decides its own padding with a literal"  "$SR" 's/\.padding\(\.vertical, SettingsMetrics\.rowVerticalInset\)/.padding(.vertical, 9)/'
mutate "a row's insets deleted outright (no literal left)" "$SR" 's/\n        \.padding\(\.vertical, SettingsMetrics\.rowVerticalInset\)//'
mutate "pane edge out of its HStack (draws horizontally)" "$SS" 's/HStack\(spacing: 0\) \{/ZStack {/'
mutate "pane rule framed by height, so it never spans"    "$SR" 's/\.frame\(width: SettingsMetrics\.paneBorderWidth\)/.frame(height: SettingsMetrics.paneBorderWidth)/'
mutate "pane translucent again (drop zone shows through)" "$SS" 's/\n        \.background\(Color\(nsColor: \.windowBackgroundColor\)\)//'
mutate "pane covers the drop label again"                 "$CV" 's/\n                \.padding\(\.trailing, model\.isSettingsOpen \? SettingsMetrics\.paneWidth : 0\)//'
mutate "pane edge removed (no boundary at all)"           "$SS" 's/            PaneDivider\(\)/            EmptyView()/'
mutate "card outline stops following Increase contrast"   "$SR" 's/contrast == \.increased \? \.labelColor : \.separatorColor/.separatorColor/'
mutate "a settings row put back into a card of its own"    "$SS" 's/SettingsGroup\(header: "実行されるコマンド（\\\(label\)）"\) \{/SettingsGroup {/'
mutate "共通パスワード no longer in the password card"      "$SS" 's/title: "共通パスワード"/title: "共通パスワード（別枠）"/'
mutate "destination path back in front of the button"     "$SS" 's/VStack\(alignment: \.trailing, spacing: 6\)/HStack(spacing: 6)/'

echo
echo "settings explanations (verified by scripts/check-tooltips.sh, not swift test):"
mutate "rows back to SwiftUI .help() (installs nothing)"  "$SR" 's/        \.explains\(help\)/        .help(help ?? "")/'                                            tooltips
mutate "tooltip shrunk to the badge instead of the row"   "$SR" 's/SystemToolTip\(text: text\)\.allowsHitTesting\(false\)/SystemToolTip(text: text).frame(width: 11, height: 11).allowsHitTesting(false)/' tooltips

echo
echo "restoring and confirming the tree is green again:"
out="$(run_suite)"; echo "  ${out}"
case "${out}" in *passed*) ;; *) echo "TREE IS NOT GREEN AFTER RESTORE" >&2; failures=$((failures + 1));; esac

if [ "${failures}" -ne 0 ]; then
  echo >&2
  echo "${failures} mutation check(s) did not behave as required" >&2
  exit 1
fi
echo "all mutations caught"
