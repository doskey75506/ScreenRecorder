#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build

# Require all supported software encoders so CI cannot pass by skipping media coverage.
for task_tool in ffmpeg ffprobe python3; do
    command -v "$task_tool" >/dev/null || { print -u2 "Missing required tool: $task_tool"; exit 1; }
done
task_encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null)"
for task_encoder in libx264 libx265 libvpx-vp9 libsvtav1 aac libopus; do
    if ! print -r -- "$task_encoders" | awk '{print $2}' | /usr/bin/grep -qx "$task_encoder"; then
        print -u2 "Missing required FFmpeg encoder: $task_encoder"
        exit 1
    fi
done
ffmpeg -version | head -n 1
ffprobe -version | head -n 1

# Swift 6.1 emits XCTest XML only through its parallel runner. One worker keeps
# media tests serial while still producing a machine-readable report.
./scripts/test.sh --verbose --parallel --num-workers 1 --xunit-output "$PWD/build/test-results.xml" 2>&1 | tee build/ci-tests.log
python3 - <<'PY'
import os
import re
from pathlib import Path
import xml.etree.ElementTree as ET

cases = list(ET.parse('build/test-results.xml').getroot().iter('testcase'))
skipped = [case for case in cases if case.find('skipped') is not None]
failed = [case for case in cases if case.find('failure') is not None or case.find('error') is not None]
# Older SwiftPM XML omits XCTest skips. Verbose output retains that information.
skipped_output = re.findall(r"^Test Case (.+) skipped \(", Path('build/ci-tests.log').read_text(), re.MULTILINE)
skip_count = max(len(skipped), len(skipped_output))
summary = f'{len(cases)} tests, {len(failed)} failures, {skip_count} skipped'
print(summary)
if path := os.environ.get('GITHUB_STEP_SUMMARY'):
    with Path(path).open('a') as report:
        report.write(f'### XCTest results\n\n{summary}\n')
if not cases or failed or skip_count:
    for case in skipped_output:
        print(f'Skipped: {case}')
    for case in skipped + failed:
        print(f"Check: {case.get('classname', '')}.{case.get('name', '')}")
    raise SystemExit('CI requires a nonempty test suite with no failures or skips.')
PY
