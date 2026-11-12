#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build/ModuleCache
./scripts/build-icon.sh
xcodebuild -quiet -project ScreenRecorder.xcodeproj -scheme ScreenRecorder \
  -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" build
echo "Built: $PWD/build/DerivedData/Build/Products/Release/ScreenRecorder.app"
