#!/bin/bash
set -x

BASE_DIR=$(realpath $(dirname ${BASH_SOURCE[0]})/..)

# sudo ${BASE_DIR}/tmp/mount_overlay_aws.sh

DEPS_INSTALL_PATH=$HOME/boki_deps/debug \
  OVERLAY_PATH=/mnt/efs_overlay/workspace/boki \
  ${BASE_DIR}/build_deps.sh --use-clang --debug

sudo ${BASE_DIR}/tmp/umount_overlay.sh
