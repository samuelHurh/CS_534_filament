#!/bin/bash
set -e

cd /mnt/code/code/CS_534_filament

mkdir -p benchmarks/baseline_off benchmarks/fov_cfg1 benchmarks/fov_cfg2 benchmarks/fov_cfg3

for i in 1 2 3 4 5; do
  echo "[baseline_off] run ${i}/5"
  sudo DISPLAY=$DISPLAY XAUTHORITY=$HOME/.Xauthority ./monitor.sh \
    --runtime 60 \
    --output-dir benchmarks/baseline_off \
    --no-foveation
done

for i in 1 2 3 4 5; do
  echo "[fov_cfg1] run ${i}/5"
  sudo DISPLAY=$DISPLAY XAUTHORITY=$HOME/.Xauthority ./monitor.sh \
    --runtime 60 \
    --output-dir benchmarks/fov_cfg1 \
    --foveation \
    --foveal-radius 0.15 \
    --peripheral-radius 0.35 \
    --transition-keep 0.5 \
    --outer-keep 0.125
done

for i in 1 2 3 4 5; do
  echo "[fov_cfg2] run ${i}/5"
  sudo DISPLAY=$DISPLAY XAUTHORITY=$HOME/.Xauthority ./monitor.sh \
    --runtime 60 \
    --output-dir benchmarks/fov_cfg2 \
    --foveation \
    --foveal-radius 0.20 \
    --peripheral-radius 0.40 \
    --transition-keep 0.6 \
    --outer-keep 0.20
done

for i in 1 2 3 4 5; do
  echo "[fov_cfg3] run ${i}/5"
  sudo DISPLAY=$DISPLAY XAUTHORITY=$HOME/.Xauthority ./monitor.sh \
    --runtime 60 \
    --output-dir benchmarks/fov_cfg3 \
    --foveation \
    --foveal-radius 0.10 \
    --peripheral-radius 0.30 \
    --transition-keep 0.4 \
    --outer-keep 0.08
done

echo "All benchmark runs completed."