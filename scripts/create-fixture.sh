#!/bin/zsh
# Optional developer fixture: animated video plus two distinct audio tracks.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build/Fixtures
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=640x360:rate=30' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
  -f lavfi -i 'sine=frequency=880:sample_rate=48000' \
  -t 4 -map 0:v -map 1:a -map 2:a -c:v libx264 -pix_fmt yuv420p \
  -c:a aac build/Fixtures/input.mp4
echo "Created build/Fixtures/input.mp4"
