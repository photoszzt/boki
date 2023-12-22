#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

rm -rf /mnt/inmem/efs_overlay
mkdir -p /mnt/inmem/efs_overlay
mkdir -p /mnt/inmem/efs_overlay/work
mkdir -p /mnt/inmem/efs_overlay/upper

mkdir -p /mnt/efs_overlay
DIR_TO_MOUNT=$(realpath $SCRIPT_DIR/../../)
mount -t overlay overlay \
  -o lowerdir=$DIR_TO_MOUNT,upperdir=/mnt/inmem/efs_overlay/upper,workdir=/mnt/inmem/efs_overlay/work \
  /mnt/efs_overlay
