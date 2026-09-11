#!/bin/bash
#================================================================================================
# rebuild-panther-x2.sh — Panther-X2 专属镜像组装(完全不依赖 Armbian)
#
# 输入三件套:
#   1. 我们自建内核的 .deb          (来自 163jm/kernel 的 Release, 含 vmlinuz/modules)
#   2. rootfs 底座 .img.gz          (来自本仓库 debian.yml 等的 Release, 单分区 ext4)
#   3. 本仓库的 u-boot/ 与 dtb/     (idbloader.img / u-boot.itb / rk3566-panther-x2.dtb)
#
# 流程: 下载解包 → 提取 rootfs → 定制(root 密码/SSH/网络/固件/模块) → 组装 GPT 镜像
#       (GPT: 16MiB 引导间隙 + 512MiB boot + N MiB root) → 写入 u-boot → xz 压缩
# 引导: u-boot distro_boot → /extlinux/extlinux.conf, 内核全内建, 无 initramfs
#
# 全程文件级操作, 不 chroot (x86 runner 处理 arm64 rootfs 无需 qemu)
# 用法: sudo bash rebuild-panther-x2.sh
#================================================================================================
set -euo pipefail

KERNEL_DEB_URL="${KERNEL_DEB_URL:?需要 KERNEL_DEB_URL}"
ROOTFS_URL="${ROOTFS_URL:?需要 ROOTFS_URL}"
FIRMWARE_URL="${FIRMWARE_URL:-}"
ROOT_MB="${ROOT_MB:-2560}"
ROOT_PASS="${ROOT_PASS:-1234}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
OUT="${OUT:-out}"
SKIP_MB=16
BOOT_MB=512

step() { echo -e "\n[STEPS] $1"; }
have() { command -v "$1" >/dev/null 2>&1; }
[[ $(id -u) -eq 0 ]] || { echo "需要 root"; exit 1; }
have python3 || { echo "需要 python3"; exit 1; }

WORK="$(mktemp -d /tmp/p2build.XXXXXX)"
mkdir -p "$OUT"
LOOP="" ; CLEANUP() {
    [[ -n "${ROOT_MNT:-}" ]] && mountpoint -q "$ROOT_MNT" && umount "$ROOT_MNT"
    [[ -n "${BOOT_MNT:-}" ]] && mountpoint -q "$BOOT_MNT" && umount "$BOOT_MNT"
    [[ -n "${SRC_MNT:-}"  ]] && mountpoint -q "$SRC_MNT"  && umount "$SRC_MNT"
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null || true
}
trap CLEANUP EXIT

step "1/7 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq dosfstools e2fsprogs parted wget gzip kmod xz-utils > /dev/null

step "2/7 下载并解包内核 deb"
cd "$WORK"
wget -q --show-progress -O kernel.deb "$KERNEL_DEB_URL"
rm -rf kernelpkg && mkdir kernelpkg
dpkg-deb -x kernel.deb kernelpkg
KVER="$(ls kernelpkg/lib/modules/ | head -1)"
VMLINUZ="kernelpkg/boot/vmlinuz-${KVER}"
[[ -f "$VMLINUZ" ]] || { echo "deb 中未找到 vmlinuz-${KVER}"; exit 1; }
echo "KVER = ${KVER}"

step "3/7 下载并提取 rootfs 底座"
wget -q --show-progress -O rootfs.img.gz "$ROOTFS_URL"
gunzip -f rootfs.img.gz
SRC_LOOP="$(losetup -P -f --show rootfs.img)"
SRC_MNT="$WORK/src_root"
mkdir -p "$SRC_MNT"
if [[ -e "${SRC_LOOP}p2" ]]; then mount "${SRC_LOOP}p2" "$SRC_MNT"; else mount "${SRC_LOOP}p1" "$SRC_MNT"; fi
[[ -d "$SRC_MNT/etc" ]] || { echo "rootfs 镜像内容异常(未找到 /etc)"; exit 1; }
echo "rootfs 底座: $(cat "$SRC_MNT/etc/os-release" | grep PRETTY_NAME | cut -d'"' -f2)"

step "4/7 定制 rootfs (root 密码 / SSH / 网络 / 模块 / 固件)"
RS="$WORK/rootfs"
cp -a "$SRC_MNT/." "$RS/"
umount "$SRC_MNT"; losetup -d "$SRC_LOOP"; SRC_MNT=""

# root 密码 (直接改 /etc/shadow, 无需 chroot)
HASH="$(python3 -c "import crypt;print(crypt.crypt('${ROOT_PASS}', crypt.mksalt(crypt.METHOD_SHA512)))")"
python3 - "$RS/etc/shadow" "$HASH" << 'PYEOF'
import sys
path, h = sys.argv[1], sys.argv[2]
out = []
for line in open(path):
    if line.startswith("root:"):
        f = line.split(":")
        f[1] = h
        line = ":".join(f)
    out.append(line)
open(path, "w").writelines(out)
PYEOF

# SSH 公钥 (可选)
if [[ -n "$SSH_PUBKEY" ]]; then
    mkdir -p "$RS/root/.ssh"
    echo "$SSH_PUBKEY" > "$RS/root/.ssh/authorized_keys"
    chmod 600 "$RS/root/.ssh/authorized_keys"
fi

# 有线网口 DHCP (systemd-networkd) + DNS
mkdir -p "$RS/etc/systemd/network" "$RS/etc/systemd/system/multi-user.target.wants"
cat > "$RS/etc/systemd/network/10-eth0.network" << 'EOF'
[Match]
Name=eth0 end0

[Network]
DHCP=yes
EOF
for s in systemd-networkd.service systemd-resolved.service ssh.service; do
    ln -sf /usr/lib/systemd/system/${s} "$RS/etc/systemd/system/multi-user.target.wants/${s}"
done
rm -f "$RS/etc/resolv.conf"; echo "nameserver 223.5.5.5" > "$RS/etc/resolv.conf"

# panther 运行时机制 (扩容/IRQ 调度/调频/swap/emmc 安装) — 来自 rootfs-overlay
REPO="$(cd "$(dirname "$0")" && pwd)"
OVERLAY="$REPO/rootfs-overlay"
if [[ -d "$OVERLAY" ]]; then
    cp -a "$OVERLAY/." "$RS/"
    chmod 755 "$RS/usr/sbin"/panther-*.sh "$RS/usr/sbin"/install-to-emmc
    chmod 644 "$RS/etc/balance_irq" "$RS/etc/modprobe.d/brcmfmac.conf" \
              "$RS/etc/default/panther-cpufreq" "$RS/etc/default/panther-swapfile"
    for u in panther-resize.service panther-irq.service panther-cpufreq.service panther-swapfile.service; do
        ln -sf "/etc/systemd/system/${u}" "$RS/etc/systemd/system/multi-user.target.wants/${u}"
    done
    echo "已安装 panther 运行时机制 (resize/irq/cpufreq/swapfile/install-to-emmc)"
fi

# 内核模块 + depmod (depmod 跨架构可用, 只解析 .ko 元数据)
mkdir -p "$RS/lib/modules"
rm -rf "$RS/lib/modules/${KVER}"
cp -a kernelpkg/lib/modules/${KVER} "$RS/lib/modules/"
rm -f "$RS/lib/modules/${KVER}/build" "$RS/lib/modules/${KVER}/source"
depmod -a -b "$RS" "${KVER}" 2>/dev/null || depmod -a "${KVER}" 2>/dev/null || true

# WiFi/BT 固件 (可选 FIRMWARE_URL: 一个 tar.gz, 解开后含 brcm/ 目录)
if [[ -n "$FIRMWARE_URL" ]]; then
    wget -q --show-progress -O firmware.tar.gz "$FIRMWARE_URL"
    mkdir -p "$RS/lib/firmware"
    tar -xzf firmware.tar.gz -C "$RS/lib/firmware/"
    echo "已安装固件"
fi
ls "$RS/lib/firmware/brcm/brcmfmac43430-sdio.bin" >/dev/null 2>&1 \
    || echo "!! 警告: 无 brcmfmac43430 固件, WiFi 将不可用 (可加 FIRMWARE_URL 重跑)"

step "5/7 创建目标镜像 (GPT: ${SKIP_MB}M 间隙 + ${BOOT_MB}M boot + ${ROOT_MB}M root)"
IMG="panther-x2-${KVER}.img"
rm -f "$IMG"
truncate -s $((SKIP_MB + BOOT_MB + ROOT_MB))M "$IMG"
parted -s "$IMG" mklabel gpt
parted -s "$IMG" mkpart BOOT ext4 ${SKIP_MB}MiB $((SKIP_MB + BOOT_MB - 1))MiB
parted -s "$IMG" mkpart ROOTFS ext4 $((SKIP_MB + BOOT_MB))MiB 100%

step "6/7 填充 boot/root 分区"
LOOP="$(losetup -P -f --show "$IMG")"
mkfs.ext4 -F -q -L BOOT   -b 4k -m 0 "${LOOP}p1"
mkfs.ext4 -F -q -L ROOTFS -b 4k -m 0 "${LOOP}p2"
BOOT_MNT="$WORK/boot_mnt"; ROOT_MNT="$WORK/root_mnt"
mkdir -p "$BOOT_MNT" "$ROOT_MNT"
mount "${LOOP}p1" "$BOOT_MNT"
mount "${LOOP}p2" "$ROOT_MNT"

# bootfs: extlinux 引导 (u-boot distro_boot 原生扫描)
BOOT_UUID="$(lsblk -no UUID "${LOOP}p1" | head -1)"
ROOT_UUID="$(lsblk -no UUID "${LOOP}p2" | head -1)"
cp "$VMLINUZ" "$BOOT_MNT/Image"
mkdir -p "$BOOT_MNT/dtb/rockchip" "$BOOT_MNT/extlinux"
REPO="$(cd "$(dirname "$0")" && pwd)"
cp "$REPO/dtb/rk3566-panther-x2.dtb" "$BOOT_MNT/dtb/rockchip/"
cat > "$BOOT_MNT/extlinux/extlinux.conf" << EOF
label panther-x2
    linux /Image
    fdt /dtb/rockchip/rk3566-panther-x2.dtb
    append root=UUID=${ROOT_UUID} rootfstype=ext4 rootwait rw console=ttyS2,1500000 console=tty0 net.ifnames=0
EOF

# rootfs: 回填 fstab, 清理构建残留
echo "UUID=${ROOT_UUID} / ext4 defaults,noatime 0 1" > "$RS/etc/fstab"
echo "UUID=${BOOT_UUID} /boot ext4 defaults 0 2"    >> "$RS/etc/fstab"
rm -rf "$RS/debootstrap" "$RS/var/cache/apt/archives/"*.deb 2>/dev/null || true
cp -a "$RS/." "$ROOT_MNT/"
sync

step "7/7 写入 u-boot 并压缩"
# rockchip 布局: idbloader → 扇区 64 (32KiB), u-boot.itb → 扇区 16384 (8MiB)
dd if="$REPO/u-boot/idbloader.img" of="$LOOP" conv=fsync,notrunc bs=512 seek=64   status=none
dd if="$REPO/u-boot/u-boot.itb"    of="$LOOP" conv=fsync,notrunc bs=512 seek=16384 status=none
sync
umount "$ROOT_MNT"; umount "$BOOT_MNT"
losetup -d "$LOOP"; LOOP=""
rm -f "$IMG.gz"
xz -9 -T0 -f "$IMG"
cp "$IMG.xz" "$OUT/" 2>/dev/null || mv "$IMG.xz" "$OUT/"
echo ""
echo "完成: ${OUT}/panther-x2-${KVER}.img.xz"
echo "烧写: xzcat panther-x2-${KVER}.img.xz | dd of=/dev/sdX bs=4M conv=fsync  (或 balenaEtcher)"
echo "登录: root / ${ROOT_PASS} (串口 ttyS2@1500000 或 SSH, 首次登录后请修改)"
