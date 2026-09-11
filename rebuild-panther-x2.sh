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
BOOT_MB=256
# 脚本所在目录(仓库根) — 必须在任何 cd 之前确定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step() { echo -e "\n[STEPS] $1"; }
have() { command -v "$1" >/dev/null 2>&1; }
[[ $(id -u) -eq 0 ]] || { echo "需要 root"; exit 1; }
have openssl || { echo "需要 openssl"; exit 1; }

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
apt-get install -y -qq dosfstools e2fsprogs parted wget gzip kmod xz-utils u-boot-tools > /dev/null

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

# root 密码 (直接改 /etc/shadow, 无需 chroot; openssl 生成 SHA512-crypt)
HASH="$(openssl passwd -6 "$ROOT_PASS")"
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
OVERLAY="${SCRIPT_DIR}/rootfs-overlay"
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

# WiFi/BT 固件: 优先仓库本地 firmware/brcm/, 其次 FIRMWARE_URL
mkdir -p "$RS/lib/firmware/brcm"
if [[ -d "${SCRIPT_DIR}/firmware/brcm" ]]; then
    cp -a "${SCRIPT_DIR}/firmware/brcm/." "$RS/lib/firmware/brcm/"
    echo "已从仓库 firmware/brcm 安装固件"
elif [[ -n "$FIRMWARE_URL" ]]; then
    wget -q --show-progress -O firmware.tar.gz "$FIRMWARE_URL"
    mkdir -p "$RS/lib/firmware"
    tar -xzf firmware.tar.gz -C "$RS/lib/firmware/"
    echo "已从 FIRMWARE_URL 安装固件"
fi
ls "$RS/lib/firmware/brcm/brcmfmac43430-sdio.bin" >/dev/null 2>&1 \
    || echo "!! 警告: 无 brcmfmac43430 固件, WiFi 将不可用"
ls "$RS/lib/firmware/brcm/brcmfmac43430-sdio.txt" >/dev/null 2>&1 \
    || echo "!! 警告: 无 nvram(.txt), WiFi 即使有 bin 也大概率起不来"

# rootfs 体积守卫: 防止 ROOT_MB 给小了导致拷贝中途爆盘
USED_MB=$(du -sm "$RS" | awk '{print $1}')
if [[ "$USED_MB" -gt $((ROOT_MB - 200)) ]]; then
    echo "!! rootfs 实际占用 ${USED_MB}MiB, 接近/超过 root 分区 ${ROOT_MB}MiB"
    echo "!! 请把 root_mb 调大 (建议 $((USED_MB + 800)) 以上), 本次继续但可能失败"
fi

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

# bootfs: 这块板的 u-boot 只认 Armbian 流程(boot.scr + bootEnv.txt), 不扫 extlinux
# 无 initramfs: booti kernel - fdt (内核全内建, root=UUID 由 rootwait 等待)
BOOT_UUID="$(lsblk -no UUID "${LOOP}p1" | head -1)"
ROOT_UUID="$(lsblk -no UUID "${LOOP}p2" | head -1)"
cp "$VMLINUZ" "$BOOT_MNT/Image"
DTB="${SCRIPT_DIR}/dtb/rk3566-panther-x2.dtb"
[[ -f "$DTB" ]] || { echo "缺少 ${DTB} — 请确认仓库已提交 dtb/rk3566-panther-x2.dtb"; exit 1; }
mkdir -p "$BOOT_MNT/dtb/rockchip"
cp "$DTB" "$BOOT_MNT/dtb/rockchip/"

cat > "$BOOT_MNT/bootEnv.txt" << EOF
verbosity=7
console=both
consoleargs=console=ttyS2,1500000 console=tty0
fdtfile=rockchip/rk3566-panther-x2.dtb
rootdev=UUID=${ROOT_UUID}
rootfstype=ext4
rootflags=rw,errors=remount-ro
extraargs=rw rootwait
extraboardargs=net.ifnames=0
overlay_prefix=rk3568
overlays=
EOF

cat > "$BOOT_MNT/boot.cmd" << 'EOF'
setenv load_addr "0x9000000"
setenv rootdev "/dev/mmcblk0p2"
setenv verbosity "1"
setenv console "both"
setenv rootfstype "ext4"
setenv rootflags "rw,errors=remount-ro"
setenv earlycon "off"

echo "Boot script loaded from ${devtype} ${devnum}"
if test -e ${devtype} ${devnum} ${prefix}bootEnv.txt; then
	load ${devtype} ${devnum} ${load_addr} ${prefix}bootEnv.txt
	env import -t ${load_addr} ${filesize}
fi

if test "${console}" = "serial" || test "${console}" = "both"; then setenv consoleargs "console=ttyS2,1500000 ${consoleargs}"; fi
if test "${console}" = "display" || test "${console}" = "both"; then setenv consoleargs "console=tty0 ${consoleargs}"; fi
if test "${earlycon}" = "on"; then setenv consoleargs "earlycon ${consoleargs}"; fi

setenv bootargs "root=${rootdev} rootwait rootfstype=${rootfstype} rootflags=${rootflags} ${consoleargs} consoleblank=0 loglevel=${verbosity} ${extraargs} ${extraboardargs}"

load ${devtype} ${devnum} ${kernel_addr_r} ${prefix}Image
load ${devtype} ${devnum} ${fdt_addr_r} ${prefix}dtb/${fdtfile}
fdt addr ${fdt_addr_r}
# 无 initramfs: 内核全内建, ramdisk 参数为 "-"
booti ${kernel_addr_r} - ${fdt_addr_r}
EOF
mkimage -C none -A arm64 -T script -d "$BOOT_MNT/boot.cmd" "$BOOT_MNT/boot.scr" > /dev/null

# rootfs: 回填 fstab, 清理构建残留
echo "UUID=${ROOT_UUID} / ext4 defaults,noatime 0 1" > "$RS/etc/fstab"
echo "UUID=${BOOT_UUID} /boot ext4 defaults 0 2"    >> "$RS/etc/fstab"
rm -rf "$RS/debootstrap" "$RS/var/cache/apt/archives/"*.deb 2>/dev/null || true
cp -a "$RS/." "$ROOT_MNT/"
sync

step "7/7 写入 u-boot 并压缩"
# rockchip 布局: idbloader → 扇区 64 (32KiB), u-boot.itb → 扇区 16384 (8MiB)
dd if="${SCRIPT_DIR}/u-boot/idbloader.img" of="$LOOP" conv=fsync,notrunc bs=512 seek=64   status=none
dd if="${SCRIPT_DIR}/u-boot/u-boot.itb"    of="$LOOP" conv=fsync,notrunc bs=512 seek=16384 status=none
sync
umount "$ROOT_MNT"; umount "$BOOT_MNT"
losetup -d "$LOOP"; LOOP=""
rm -f "$IMG.gz"
xz -9 -T0 -f "$IMG"
cp "$IMG.xz" "$OUT/" 2>/dev/null || mv "$IMG.xz" "$OUT/"
# 产物交还给调用用户(sudo 场景下避免 root 属主导致后续 mv 失败)
if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "${SUDO_USER}" "$OUT" 2>/dev/null || true
fi
echo ""
echo "完成: ${OUT}/panther-x2-${KVER}.img.xz"
echo "烧写: xzcat panther-x2-${KVER}.img.xz | dd of=/dev/sdX bs=4M conv=fsync  (或 balenaEtcher)"
echo "登录: root / ${ROOT_PASS} (串口 ttyS2@1500000 或 SSH, 首次登录后请修改)"
