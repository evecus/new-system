#!/bin/sh
# 首次启动自动扩容: root 分区扩展到磁盘末尾 + resize2fs
# 纯 util-linux 实现(blockdev --resize-partition), 不依赖 growpart/parted
MARKER=/var/lib/panther/resize-done
mkdir -p /var/lib/panther
[ -f "$MARKER" ] && exit 0

ROOT_DEV=$(findmnt -no SOURCE /) 2>/dev/null || ROOT_DEV=""
[ -n "$ROOT_DEV" ] || exit 0
case "$ROOT_DEV" in
    *mmcblk*p[0-9]|*nvme*p[0-9]|*[sv]d[a-z][0-9]) ;;
    *) echo "root 分区格式无法识别: $ROOT_DEV"; exit 0 ;;
esac
DISK=${ROOT_DEV%p[0-9]*}
PART=${ROOT_DEV##*/}
SYS=/sys/class/block/$PART
DISK_SYS=/sys/class/block/${DISK##*/}

START=$(cat "$SYS/start")
DISK_SECT=$(cat "$DISK_SYS/size")
CUR_SECT=$(cat "$SYS/size")
NEW_SECT=$((DISK_SECT - START))
if [ "$NEW_SECT" -le "$CUR_SECT" ]; then
    echo "root 分区已到磁盘末尾, 无需扩容"
    touch "$MARKER"
    exit 0
fi

echo "扩容 $ROOT_DEV: ${CUR_SECT} -> ${NEW_SECT} 扇区"
# blockdev --resize-partition 参数为字节数
if blockdev --resize-partition "$ROOT_DEV" $((NEW_SECT * 512)) 2>/dev/null; then
    resize2fs "$ROOT_DEV" && touch "$MARKER" && echo "扩容完成"
else
    echo "blockdev 扩容失败(内核/工具不支持), 跳过"
fi
exit 0
