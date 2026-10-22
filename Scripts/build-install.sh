#!/bin/zsh
# Builds WhatPort in Release, signs it ad hoc and installs it into
# ~/Applications (or the directory given as the first argument).
#
#   Scripts/build-install.sh                 # build + install + launch
#   Scripts/build-install.sh /Applications   # install system-wide
#   Scripts/build-install.sh --no-launch     # build + install only
#   Scripts/build-install.sh --build-only    # just produce dist/WhatPort.app
set -euo pipefail

cd "$(dirname "$0")/.."

destination="$HOME/Applications"
launch=1
install=1
for argument in "$@"; do
  case "$argument" in
    --no-launch) launch=0 ;;
    --build-only) install=0; launch=0 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) destination="$argument" ;;
  esac
done

if ! command -v xcodebuild >/dev/null; then
  echo "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

if [[ ! -d WhatPort.xcodeproj ]]; then
  if command -v xcodegen >/dev/null; then
    xcodegen generate
  else
    echo "WhatPort.xcodeproj is missing and xcodegen is not installed (brew install xcodegen)." >&2
    exit 1
  fi
fi

echo "▸ Building Release…"
xcodebuild \
  -project WhatPort.xcodeproj \
  -scheme WhatPort \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  build 2>&1 | grep -E "error:|warning: [^M]|BUILD" || true

app="build/DerivedData/Build/Products/Release/WhatPort.app"
if [[ ! -d "$app" ]]; then
  echo "Build failed: $app not found." >&2
  exit 1
fi

mkdir -p dist
rm -rf dist/WhatPort.app
ditto "$app" dist/WhatPort.app
# Ad-hoc signature: valid indefinitely on this machine, no developer account needed.
codesign --force --deep --sign - --options runtime dist/WhatPort.app
codesign --verify --deep --strict dist/WhatPort.app
echo "▸ Built dist/WhatPort.app ($(defaults read "$PWD/dist/WhatPort.app/Contents/Info.plist" CFBundleShortVersionString))"

if (( install )); then
  if pgrep -xq WhatPort; then
    echo "▸ Quitting running WhatPort…"
    osascript -e 'tell application id "com.karrtopelka.whatport" to quit' >/dev/null 2>&1 || pkill -x WhatPort || true
    sleep 1
  fi
  mkdir -p "$destination"
  rm -rf "$destination/WhatPort.app"
  ditto dist/WhatPort.app "$destination/WhatPort.app"
  echo "▸ Installed to $destination/WhatPort.app"
  if (( launch )); then
    open "$destination/WhatPort.app"
    echo "▸ Launched. Look for the network icon in your menu bar."
  fi
fi
