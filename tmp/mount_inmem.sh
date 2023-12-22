#!/bin/bash

set -euo pipefail
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

sudo mkdir -p /mnt/inmem
if mountpoint -q "/mnt/inmem"; then
  echo "/mnt/inmem already mounted"
else
  sudo mount -t tmpfs -o size=8192M -o rw,nosuid,nodev tmpfs /mnt/inmem
fi
