#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build/ModuleCache
./scripts/build-icon.sh
# Supply the same Apple Development / Developer ID identity for every local
# update to preserve the designated requirement used by macOS privacy grants.
task_signing_args=()
if [[ -n "${SCREENRECORDER_SIGN_IDENTITY:-}" ]]; then
  task_signing_args+=("CODE_SIGN_IDENTITY=$SCREENRECORDER_SIGN_IDENTITY")
else
  print -u2 "Using ad hoc signing: updates may require granting Screen Recording access again."
fi
xcodebuild -quiet -project ScreenRecorder.xcodeproj -scheme ScreenRecorder \
  -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" "${task_signing_args[@]}" build
echo "Built: $PWD/build/DerivedData/Build/Products/Release/ScreenRecorder.app"
