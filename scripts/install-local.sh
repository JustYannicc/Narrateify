#!/bin/zsh
# Build Release, sign it with a stable local identity, install to /Applications
# and relaunch. Ad-hoc builds change their signature on every rebuild, so macOS
# silently drops the Accessibility grant (the toggle stays on, capture fails).
# A fixed certificate keeps the grant across rebuilds.
#
#   NARRATEIFY_SIGN_IDENTITY="My Local Signing" scripts/install-local.sh
# Defaults to the first valid code-signing identity in the keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

identity=${NARRATEIFY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' 'NR==1 {print $2}')}
[[ -n "$identity" ]] || { echo "No code-signing identity found; create one in Keychain Access → Certificate Assistant." >&2; exit 1; }

xcodegen -q
# Plugin/macro validation would block on an approval prompt (mlx-swift, swift-transformers).
xcodebuild -project Narrateify.xcodeproj -scheme Narrateify -configuration Release \
  -derivedDataPath /tmp/narr-dd -skipPackagePluginValidation -skipMacroValidation build -quiet

app=/tmp/narr-dd/Build/Products/Release/Narrateify.app
# --deep skips SharedSupport, so sign the bundled tools first.
codesign --force --options runtime --identifier com.narrateify.cli --sign "$identity" "$app/Contents/SharedSupport/narrateify"
codesign --force --options runtime --identifier com.narrateify.qwen3 --sign "$identity" "$app/Contents/SharedSupport/narrateify-qwen3"
codesign --force --deep --options runtime --sign "$identity" "$app"
codesign --verify --strict "$app"

pkill -x Narrateify 2>/dev/null && sleep 1 || true
rm -rf /Applications/Narrateify.app
ditto "$app" /Applications/Narrateify.app
open /Applications/Narrateify.app
/Applications/Narrateify.app/Contents/SharedSupport/narrateify install-cli   # CLI → ~/.local/bin
echo "Installed, signed with \"$identity\"."
