#!/bin/bash
# Downloads the official 7-Zip console binary and refuses to install it unless the
# SHA-256 matches. Re-running is cheap: it exits early if the binary is already there.
set -euo pipefail

VERSION="26.02"
ARCHIVE="7z2602-mac.tar.xz"
URL="https://github.com/ip7z/7zip/releases/download/${VERSION}/${ARCHIVE}"
SHA256="1cf6760579502f87e591ff5c73a005ec50b3e4d6f507e8b038382d563c3175b9"
BYTES="1859992"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="${ROOT}/vendor"
DOWNLOAD="${VENDOR}/download"
EXTRACT="${VENDOR}/ex"

if [ -x "${EXTRACT}/7zz" ] && [ -f "${EXTRACT}/License.txt" ]; then
  echo "7zz already present: ${EXTRACT}/7zz"
  "${EXTRACT}/7zz" i 2>/dev/null | head -1
  exit 0
fi

mkdir -p "${DOWNLOAD}" "${EXTRACT}"
echo "Downloading ${URL}"
curl -fsSL -o "${DOWNLOAD}/${ARCHIVE}" "${URL}"

actual_bytes="$(stat -f%z "${DOWNLOAD}/${ARCHIVE}")"
actual_sha="$(shasum -a 256 "${DOWNLOAD}/${ARCHIVE}" | awk '{print $1}')"

if [ "${actual_bytes}" != "${BYTES}" ]; then
  echo "FAILED: size mismatch (got ${actual_bytes}, want ${BYTES})" >&2
  rm -f "${DOWNLOAD}/${ARCHIVE}"
  exit 1
fi
if [ "${actual_sha}" != "${SHA256}" ]; then
  echo "FAILED: SHA-256 mismatch" >&2
  echo "  got  ${actual_sha}" >&2
  echo "  want ${SHA256}" >&2
  rm -f "${DOWNLOAD}/${ARCHIVE}"
  exit 1
fi
echo "SHA-256 verified: ${actual_sha}"

tar -xJf "${DOWNLOAD}/${ARCHIVE}" -C "${EXTRACT}"
chmod +x "${EXTRACT}/7zz"
"${EXTRACT}/7zz" i | head -1
