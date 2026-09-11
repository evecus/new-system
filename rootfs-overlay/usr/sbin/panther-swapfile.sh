#!/bin/sh
# 按 /etc/default/panther-swapfile 创建/启用 swapfile
[ -r /etc/default/panther-swapfile ] && . /etc/default/panther-swapfile
[ "${ENABLE}" = "true" ] || exit 0
SIZE_MB="${SIZE_MB:-2048}"
SWAP=/swapfile
if [ ! -f "$SWAP" ]; then
    dd if=/dev/zero of="$SWAP" bs=1M count="$SIZE_MB" conv=fsync
    chmod 600 "$SWAP"; mkswap "$SWAP"
fi
swapon "$SWAP" 2>/dev/null || true
