#!/bin/bash
# Assembles "7Zip Drop.app" from the SwiftPM build product, the vendored 7zz and the
# generated icon, then ad-hoc signs it (helper first, so the outer seal stays valid).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP_NAME="7Zip Drop"
BUNDLE_ID="com.local.sevenzip-compressor"
BUILD_DIR="${ROOT}/build"
APP="${BUILD_DIR}/${APP_NAME}.app"
BINARY_NAME="SevenZipCompressorApp"

SEVEN_ZIP="${ROOT}/vendor/ex/7zz"
if [ ! -x "${SEVEN_ZIP}" ]; then
  echo "vendored 7zz missing; running scripts/fetch-7zz.sh" >&2
  "${ROOT}/scripts/fetch-7zz.sh"
fi

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}" --package-path "${ROOT}"
PRODUCT="$(swift build -c "${CONFIG}" --package-path "${ROOT}" --show-bin-path)/${BINARY_NAME}"
test -x "${PRODUCT}" || { echo "build product not found: ${PRODUCT}" >&2; exit 1; }

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" \
         "${APP}/Contents/Helpers" \
         "${APP}/Contents/Resources/ThirdParty/7-Zip"

cp "${PRODUCT}" "${APP}/Contents/MacOS/${BINARY_NAME}"
cp "${SEVEN_ZIP}" "${APP}/Contents/Helpers/7zz"
chmod +x "${APP}/Contents/Helpers/7zz"
cp "${ROOT}/vendor/ex/License.txt" "${APP}/Contents/Resources/ThirdParty/7-Zip/License.txt"
cp "${ROOT}/vendor/ex/readme.txt"  "${APP}/Contents/Resources/ThirdParty/7-Zip/readme.txt"
cp "${ROOT}/NOTICE.md"             "${APP}/Contents/Resources/ThirdParty/NOTICE.md"

printf 'APPL????' > "${APP}/Contents/PkgInfo"

VERSION="$(sed -n 's/^version: *//p' "${ROOT}/VERSION" 2>/dev/null || true)"
VERSION="${VERSION:-1.0.0}"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>CFBundleExecutable</key><string>${BINARY_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key>
    <string>Uses 7-Zip (C) 1999-2026 Igor Pavlov, GNU LGPL — https://www.7-zip.org/</string>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>圧縮するファイル</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key><array><string>public.item</string></array>
            <!-- None: accept Dock drops and "Open With" without ever becoming the
                 default application for any file type. -->
            <key>LSHandlerRank</key><string>None</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> icon"
ICON_ART="${ROOT}/Resources/AppIcon-1024.png"
test -f "${ICON_ART}" || { echo "icon artwork missing: ${ICON_ART}" >&2; exit 1; }
if command -v iconutil >/dev/null 2>&1; then
  swift "${ROOT}/scripts/make-icon.swift" "${BUILD_DIR}" >/dev/null
  # All ten slices, or the Dock silently falls back to a blurred upscale.
  SLICES="$(ls "${BUILD_DIR}/AppIcon.iconset" | grep -c '\.png$')"
  test "${SLICES}" -eq 10 || { echo "iconset has ${SLICES} slices, expected 10" >&2; exit 1; }
  iconutil -c icns "${BUILD_DIR}/AppIcon.iconset" -o "${APP}/Contents/Resources/AppIcon.icns"
  test -s "${APP}/Contents/Resources/AppIcon.icns" || { echo "icns not written" >&2; exit 1; }
  rm -rf "${BUILD_DIR}/AppIcon.iconset"
else
  echo "   iconutil unavailable; shipping without an icon" >&2
fi

echo "==> ad-hoc signing (nested helper first)"
codesign --force --sign - --timestamp=none "${APP}/Contents/Helpers/7zz"
codesign --force --sign - --timestamp=none "${APP}"
codesign --verify --deep --strict --verbose=1 "${APP}"

echo
echo "Built: ${APP}"
echo "Run with:  open '${APP}'"
