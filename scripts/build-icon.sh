#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
if [[ -f Config/AppIcon.icns && Config/AppIcon.icns -nt Assets/AppIcon.png ]]; then
    exit 0
fi
task_iconset="$PWD/build/AppIcon.iconset"
mkdir -p "$task_iconset"
for task_size in 16 32 128 256 512; do
    sips -z "$task_size" "$task_size" Assets/AppIcon.png \
        --out "$task_iconset/icon_${task_size}x${task_size}.png" >/dev/null
    task_retina=$((task_size * 2))
    sips -z "$task_retina" "$task_retina" Assets/AppIcon.png \
        --out "$task_iconset/icon_${task_size}x${task_size}@2x.png" >/dev/null
done
if ! iconutil -c icns "$task_iconset" -o Config/AppIcon.icns 2>/dev/null; then
    python3 scripts/pack-icon.py "$task_iconset" Config/AppIcon.icns
fi
