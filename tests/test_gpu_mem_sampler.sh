#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yauhen Bichel
#
# gpu-mem-sampler on a fake machine: sysfs and /proc under SF_ROOT, ps and nvidia-smi stubbed.
# Stub bodies are single-quoted on purpose: they expand when the stub runs.
# shellcheck source-path=SCRIPTDIR disable=SC2016
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
S=$HERE/bin/gpu-mem-sampler
R=$T/root
export SF_ROOT=$R
mkdir -p "$R/sys/class/drm/card1/device" "$R/proc"
echo 22226455552 > "$R/sys/class/drm/card1/device/mem_info_vram_used"
echo 0 > "$R/sys/class/drm/card1/device/mem_info_gtt_used"
printf 'MemTotal:       65435652 kB\nMemAvailable:   48339354 kB\nSwapTotal:       8388604 kB\nSwapFree:        4194300 kB\n' > "$R/proc/meminfo"
stub ps 'echo "10078208 python"'

run "$S" --once
expect "one line from amdgpu's sysfs, meminfo and the largest process" 0 \
  '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z gtt=0\.0 vram=20\.7 avail=46\.1 swap=4\.0 top=python:9\.6$'

rm -rf "$R/sys/class/drm/card1"
stub nvidia-smi 'echo 8192'
run "$S" --once
expect "with no amdgpu sysfs, vram comes from nvidia-smi" 0 'gtt=- vram=8\.0 avail=46\.1'

rm -f "$T/bin/nvidia-smi"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  run "$S" --once
  expect "with no GPU information at all, vram is a dash" 0 'gtt=- vram=- avail=46\.1'
fi

"$S" --interval 1 --log "$T/gpu.log" --max-bytes 50 &
pid=$!
sleep 2.5
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
if [ -s "$T/gpu.log.1" ]; then pass "the log rotates at --max-bytes"; else failed "the log rotates at --max-bytes" "$(ls -la "$T")"; fi

run "$S" --interval 0
expect "--interval 0 is a usage error" 2 "whole numbers"
finish
