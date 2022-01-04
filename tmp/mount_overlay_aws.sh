#!/bin/bash

rm -rf /mnt/inmem/efs_overlay
mkdir /mnt/inmem/efs_overlay
mkdir /mnt/inmem/efs_overlay/work
mkdir /mnt/inmem/efs_overlay/upper

mkdir -p /mnt/efs_overlay
mount -t overlay overlay \
  -o lowerdir=/mnt/efs/,upperdir=/mnt/inmem/efs_overlay/upper,workdir=/mnt/inmem/efs_overlay/work \
  /mnt/efs_overlay
