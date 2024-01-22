#!/bin/bash
set -x

BASE_DIR=$(realpath $(dirname ${BASH_SOURCE[0]})/..)

# sudo ${BASE_DIR}/tmp/mount_overlay.sh
# OVERLAY_PATH=/mnt/efs_overlay/boki \
cd ${BASE_DIR}
git submodule update --init --recursive
cd -

DEPS_INSTALL_PATH=$BASE_DIR/../boki_deps/release \
  ${BASE_DIR}/build_deps.sh

# sudo ${BASE_DIR}/tmp/umount_overlay.sh
