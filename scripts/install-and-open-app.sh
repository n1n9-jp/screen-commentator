#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${HOME}/Applications"
INSTALL_APP="${INSTALL_DIR}/ScreenCommentator.app"
BUILT_APP="${ROOT_DIR}/DerivedData/Build/Products/Debug/ScreenCommentator.app"
SIGNING_IDENTITY="${SCREEN_COMMENTATOR_CODE_SIGN_IDENTITY:-}"

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning "${HOME}/Library/Keychains/login.keychain-db" \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1
  )"
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="ScreenCommentator Local Code Signing"
fi

cd "${ROOT_DIR}"

osascript -e 'if application id "com.local.screencommentator" is running then tell application id "com.local.screencommentator" to quit' || true
sleep 1

xcodegen generate
xcodebuild \
  -project ScreenCommentator.xcodeproj \
  -scheme ScreenCommentator \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  build

mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_APP}"
ditto "${BUILT_APP}" "${INSTALL_APP}"

if [[ "${SIGNING_IDENTITY}" == "ScreenCommentator Local Code Signing" ]]; then
  "${ROOT_DIR}/scripts/ensure-local-codesign-identity.sh" "${SIGNING_IDENTITY}"
fi
codesign \
  --force \
  --deep \
  --sign "${SIGNING_IDENTITY}" \
  --entitlements "${ROOT_DIR}/ScreenCommentator/Resources/ScreenCommentator.entitlements" \
  --options runtime \
  --timestamp=none \
  "${INSTALL_APP}"
codesign --verify --deep --strict --verbose=2 "${INSTALL_APP}"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f \
  -R \
  -trusted \
  "${INSTALL_APP}"

echo "Installed ${INSTALL_APP}"
echo "Signed with ${SIGNING_IDENTITY}"
echo "Open System Settings > Privacy & Security > Screen & System Audio Recording and enable ScreenCommentator for this installed app."

open "${INSTALL_APP}"
