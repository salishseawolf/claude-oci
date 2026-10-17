#!/bin/bash
set -e

# Activate mise environment
eval "$(mise activate bash)"

# Nested Podman: use fuse-overlayfs storage when /dev/fuse was passed in
# (`--device /dev/fuse`), otherwise keep the vfs default from storage.conf.
# Exported here so Claude Code and every shell it spawns inherit it.
if [ -c /dev/fuse ] && [ -z "${CONTAINERS_STORAGE_CONF:-}" ]; then
  export CONTAINERS_STORAGE_CONF=/etc/containers/storage-overlay.conf
fi

# Execute claude with all arguments, replacing this process
exec claude "$@"
