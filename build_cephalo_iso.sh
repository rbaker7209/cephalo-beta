#!/usr/bin/env bash
#
# build-cephalo-iso.sh — the Cephalo ISO builder.
#
# Builds a stripped-down, hybrid BIOS/UEFI, live-bootable Debian Trixie ISO
# whose only job is to run the Cephalo installer. The live image is a bare
# command-line system (no display stack, no desktop, no browser) but keeps
# everything that decides whether it can get online or boot on a given
# machine: broad Wi-Fi/Ethernet firmware, the Broadcom STA driver, the
# wireless regulatory database, and ALL Intel/AMD CPU microcode.
#
# The installer is a SEPARATE script (install-cephalo.sh). This builder rolls
# a copy of it, plus the selected custom kernel, into the ISO under
# /opt/cephalo and adds a `cephalo-install` launcher to the live session.
# The system the installer puts on disk is the full desktop; only the
# installer ISO is minimal.
#
# Run as root on a Debian/Ubuntu build host with network access.
# install-cephalo.sh must sit next to this script (or set INSTALLER_SRC).
#
# Usage:
#   sudo ./build-cephalo-iso.sh
#   sudo KERNEL_TARGET="v1" ./build-cephalo-iso.sh
#   sudo KERNEL_TARGET="amd-piledriver" KERNELS_DIR="/path/to/kernels" ./build-cephalo-iso.sh
#   sudo INSTALLER_SRC=/path/to/install-cephalo.sh ./build-cephalo-iso.sh

set -euo pipefail

# ============================== CONFIG =====================================

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"

REAL_USER="${SUDO_USER:-${USER:-root}}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
WORK="${WORK:-$REAL_HOME/cephalo-build}"
CHROOT="$WORK/chroot"
ISO="$WORK/iso"
OUT="$WORK/cephalo-live-amd64.iso"

# The installer script that gets rolled into the ISO
INSTALLER_SRC="${INSTALLER_SRC:-$SELF_DIR/install_cephalo.sh}"

# Custom Kernel Configuration
KERNELS_DIR="${KERNELS_DIR:-$REAL_HOME/kernels}"
KERNEL_TARGET="${KERNEL_TARGET:-v1}"

DEBIAN_MIRROR="http://deb.debian.org/debian"
SUITE="trixie"

HOSTNAME="cephalo-live"
LOCALE="en_US.UTF-8"
KEYBOARD_LAYOUT="us"

ROOT_PASS="root"          # root password for other ttys (tty1 auto-logs in as root)

OVERLAY_DIR="${OVERLAY_DIR:-}"

# --- Hardware-compatibility toggles ---------------------------------------
INCLUDE_BROADCOM_STA="${INCLUDE_BROADCOM_STA:-1}"   # proprietary driver for many older Broadcom Wi-Fi chips
ENABLE_TORAM="${ENABLE_TORAM:-1}"
# Boot with nomodeset: the installer only needs a text console, and this lets
# us ship no GPU firmware at all while still showing a console on any GPU.
CONSOLE_NOMODESET="${CONSOLE_NOMODESET:-1}"
# 1 = run cephalo-install automatically on the tty1 login; 0 = just show a banner
LAUNCH_INSTALLER_ON_LOGIN="${LAUNCH_INSTALLER_ON_LOGIN:-0}"

# --- Live image package sets (command line only) -------------------------
# Core: init, initramfs tooling, and the whole Wi-Fi stack. wireless-regdb is
# required for 5 GHz channels (it is only a Recommends, which we disable).
BASE_PKGS="systemd-sysv initramfs-tools zstd kmod network-manager wpasupplicant wireless-regdb"
# Small helpers for getting online / diagnosing hardware (installed tolerantly)
TOOL_PKGS="iw rfkill kbd pciutils usbutils"

MICROCODE_PKGS="intel-microcode amd64-microcode"
# Network firmware only: Wi-Fi first, plus the Ethernet NICs that refuse to
# work without blobs. No GPU, sound or other firmware (the console runs on
# the firmware framebuffer via nomodeset).
FIRMWARE_PKGS="firmware-iwlwifi firmware-atheros firmware-realtek firmware-brcm80211 firmware-ath9k-htc firmware-libertas firmware-ralink firmware-mediatek firmware-misc-nonfree firmware-bnx2 firmware-bnx2x"

# Build tools needed only to compile the Broadcom module; removed afterwards
DKMS_PKGS="build-essential dkms"
BROADCOM_STA_PKGS="broadcom-sta-dkms"

LIVE_PKGS="live-boot live-boot-initramfs-tools"
# Tools needed inside the live image to run the installer:
INSTALLER_PKGS="debootstrap debian-archive-keyring ca-certificates wget parted dosfstools e2fsprogs util-linux whiptail zstd tar"
PAYLOAD_DIR="/opt/cephalo"      # where the installer + kernel live inside the ISO

# =========================== END CONFIG =====================================

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$1"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run this as root (sudo)."; }

KERNEL_SRC=""             # directory the custom kernel files were taken from

HOST_DEPS="debootstrap squashfs-tools xorriso isolinux syslinux-common \
grub-pc-bin grub-efi-amd64-bin mtools dosfstools rsync zstd"

install_host_deps() {
    log "Installing host build dependencies"
    apt-get update -qq
    # shellcheck disable=SC2086
    apt-get install -y $HOST_DEPS
}

MOUNTED=0

MOUNTED=0
cleanup() {
    if [ "$MOUNTED" -eq 1 ]; then
        log "Cleaning up chroot mounts"
        for m in dev/pts dev proc sys run; do
            mountpoint -q "$CHROOT/$m" && umount -lf "$CHROOT/$m" || true
        done
        MOUNTED=0
    fi
}
trap cleanup EXIT INT TERM

resolve_kernel_dir() {
    [ -d "$KERNELS_DIR" ] || die "KERNELS_DIR does not exist: $KERNELS_DIR"

    local raw_target="$KERNEL_TARGET"
    local target="${raw_target//_/-}"
    local match=""

    for category in chipsets versions; do
        local cat_dir="$KERNELS_DIR/$category"
        if [ -d "$cat_dir" ]; then
            for kpath in "$cat_dir"/*; do
                if [ -d "$kpath" ]; then
                    local folder_name
                    folder_name="$(basename "$kpath")"
                    local norm_folder="${folder_name//_/-}"
                    if [ "$norm_folder" = "$target" ] || [[ "$norm_folder" == *"$target"* ]]; then
                        match="$kpath"
                        break 2
                    fi
                fi
            done
        fi
    done

    if [ -z "$match" ]; then
        die "No custom kernel matching target '$raw_target' found in $KERNELS_DIR/chipsets or $KERNELS_DIR/versions"
    fi

    echo "$match"
}

prepare_custom_kernel() {
    KERNEL_SRC="$(resolve_kernel_dir)"
    log "Selected custom kernel directory: $KERNEL_SRC"

    mkdir -p "$CHROOT/tmp/custom_kernel"
    rm -rf "$CHROOT/tmp/custom_kernel/"*
    cp -a "$KERNEL_SRC"/* "$CHROOT/tmp/custom_kernel/"
}

debootstrap_base() {
    log "debootstrapping $SUITE into $CHROOT"
    mkdir -p "$CHROOT"
    if [ -f "$CHROOT/etc/debian_version" ]; then
        log "Chroot already bootstrapped, skipping debootstrap"
        return
    fi
    debootstrap --arch=amd64 --variant=minbase "$SUITE" "$CHROOT" "$DEBIAN_MIRROR"
}

mount_chroot() {
    mount --bind /dev "$CHROOT/dev"
    mount --bind /dev/pts "$CHROOT/dev/pts"
    mount -t proc proc "$CHROOT/proc"
    mount -t sysfs sys "$CHROOT/sys"
    cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
    MOUNTED=1
}

write_chroot_script() {
    log "Writing in-chroot setup script"

    cat > "$CHROOT/root/setup.sh" <<CHROOTEOF
#!/usr/bin/env bash
set -euo pipefail

echo 'APT::Install-Recommends "0";' > /etc/apt/apt.conf.d/99no-recommends

# Don't install docs, man/info pages or translations (copyright files stay)
cat > /etc/dpkg/dpkg.cfg.d/99-cephalo-slim <<EOF
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/locale.alias
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/bug/*
EOF

cat > /etc/apt/sources.list <<EOF
deb $DEBIAN_MIRROR $SUITE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $SUITE-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $SUITE-security main contrib non-free non-free-firmware
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update

# core system + Wi-Fi stack (must succeed)
apt-get install -y $BASE_PKGS

# UTF-8 console without the locales package; hostname
echo 'LANG=C.UTF-8' > /etc/default/locale
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
EOF

# small helper tools (nice to have)
FAILED_TOOLS=""
for pkg in $TOOL_PKGS; do
    apt-get install -y "\$pkg" || FAILED_TOOLS="\$FAILED_TOOLS \$pkg"
done
[ -n "\$FAILED_TOOLS" ] && echo "WARNING: failed to install:\$FAILED_TOOLS" >&2

# --- Custom Kernel Installation ---
echo "Installing custom kernel from staged files..."
if ls /tmp/custom_kernel/*.deb >/dev/null 2>&1; then
    apt-get install -y /tmp/custom_kernel/*.deb
else
    cp -f /tmp/custom_kernel/vmlinuz-* /boot/ 2>/dev/null || true
    cp -f /tmp/custom_kernel/initrd.img-* /boot/ 2>/dev/null || true
    cp -f /tmp/custom_kernel/System.map-* /boot/ 2>/dev/null || true
    cp -f /tmp/custom_kernel/config-* /boot/ 2>/dev/null || true

    if [ -d /tmp/custom_kernel/lib/modules ]; then
        mkdir -p /lib/modules
        cp -a /tmp/custom_kernel/lib/modules/* /lib/modules/
    fi
    if [ -d /tmp/custom_kernel/usr/src ]; then
        mkdir -p /usr/src
        cp -a /tmp/custom_kernel/usr/src/* /usr/src/ 2>/dev/null || true
    fi
fi
rm -rf /tmp/custom_kernel

# --- CPU microcode (all CPUs, not just the build host) ---------------------
FAILED_UCODE=""
for pkg in $MICROCODE_PKGS; do
    apt-get install -y "\$pkg" || FAILED_UCODE="\$FAILED_UCODE \$pkg"
done
[ -n "\$FAILED_UCODE" ] && echo "WARNING: failed to install:\$FAILED_UCODE" >&2

# This image boots on arbitrary machines: bundle microcode for EVERY Intel
# CPU family in the initramfs instead of only the CPU of the build host.
if [ -f /etc/default/intel-microcode ]; then
    sed -i -e 's/^#\\?IUCODE_TOOL_INITRAMFS=.*/IUCODE_TOOL_INITRAMFS=yes/' \\
           -e 's/^#\\?IUCODE_TOOL_SCANCPUS=.*/IUCODE_TOOL_SCANCPUS=no/' /etc/default/intel-microcode
fi

# --- Network firmware ------------------------------------------------------
FAILED_FW=""
for pkg in $FIRMWARE_PKGS; do
    apt-get install -y "\$pkg" || FAILED_FW="\$FAILED_FW \$pkg"
done
[ -n "\$FAILED_FW" ] && echo "WARNING: failed to install:\$FAILED_FW (continuing without them)" >&2

for fwdir in iwlwifi brcm ath10k rtlwifi rtw88 rtw89 mediatek ; do
    if [ -d "/lib/firmware/\$fwdir" ] && [ -n "\$(ls -A "/lib/firmware/\$fwdir" 2>/dev/null)" ]; then
        echo "firmware check: /lib/firmware/\$fwdir populated (\$(ls -1 "/lib/firmware/\$fwdir" | wc -l) files)"
    else
        echo "WARNING: /lib/firmware/\$fwdir is missing or empty — matching Wi-Fi hardware will fail to init" >&2
    fi
done

# --- Broadcom STA (proprietary) Wi-Fi driver -------------------------------
# Built once here with DKMS against the custom kernel; the compiler toolchain
# is then removed again so it doesn't bloat the image.
if [ "$INCLUDE_BROADCOM_STA" = "1" ]; then
    echo "Attempting Broadcom STA driver installation..."
    apt-get install -y $DKMS_PKGS
    if apt-get install -y $BROADCOM_STA_PKGS; then
        apt-mark manual dkms $BROADCOM_STA_PKGS >/dev/null || true
    else
        echo "WARNING: broadcom-sta-dkms failed to install/build (missing custom kernel headers). Purging package to unblock package manager..." >&2
        apt-get purge -y $BROADCOM_STA_PKGS dkms || true
        BCM_BLACKLIST_FILES=\$(dpkg -L broadcom-sta-dkms 2>/dev/null | grep '^/etc/modprobe\.d/' || true)
        if [ -n "\$BCM_BLACKLIST_FILES" ]; then
            rm -f \$BCM_BLACKLIST_FILES
        fi
    fi
    apt-get purge -y build-essential || true
    apt-get autoremove -y --purge || true
fi

# --- Live-boot + the tools the installer needs ------------------------------
apt-get install -y $LIVE_PKGS
apt-get install -y $INSTALLER_PKGS

# --- Network ---------------------------------------------------------------
systemctl enable NetworkManager.service
systemctl disable NetworkManager-wait-online.service || true

# --- Console: autologin as root on tty1, with a how-to banner ---------------
echo "root:${ROOT_PASS}" | chpasswd

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \\\$TERM
EOF

cat > /etc/profile.d/cephalo-banner.sh <<'EOF'
if [ "\$(id -u)" -eq 0 ] && [ -t 1 ]; then
    printf '\n  Cephalo installer\n\n'
    printf '    cephalo-install    start the installer\n'
    printf '    nmtui              connect to Wi-Fi / network\n'
    printf '    loadkeys <layout>  change keyboard layout (e.g. loadkeys de)\n\n'
    if [ "$LAUNCH_INSTALLER_ON_LOGIN" = "1" ] && [ "\$(tty)" = "/dev/tty1" ]; then
        exec cephalo-install
    fi
fi
EOF

# --- Force Initramfs Creation for Custom Kernels ---
if [ -d /lib/modules ]; then
    for kvers in \$(ls /lib/modules); do
        echo "Generating initramfs for kernel version: \$kvers"
        depmod -a "\$kvers" || true
        update-initramfs -c -k "\$kvers" || update-initramfs -u -k "\$kvers" || true
    done
fi

# --- Final slimming ---
find /usr/share/doc -type f ! -name copyright -delete 2>/dev/null || true
find /usr/share/doc -type d -empty -delete 2>/dev/null || true
rm -rf /usr/share/man/* /usr/share/info/*
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name locale.alias -exec rm -rf {} + 2>/dev/null || true

apt-get clean
rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/* /var/cache/apt/* /var/log/*.log /var/log/apt
CHROOTEOF
    chmod +x "$CHROOT/root/setup.sh"
}

run_chroot_setup() {
    log "Running setup inside chroot (this is the long step)"
    chroot "$CHROOT" /root/setup.sh
    rm -f "$CHROOT/root/setup.sh"
}

apply_overlay() {
    [ -n "$OVERLAY_DIR" ] || return 0
    [ -d "$OVERLAY_DIR" ] || die "OVERLAY_DIR set but not a directory: $OVERLAY_DIR"
    log "Applying overlay from $OVERLAY_DIR"
    rsync -a "$OVERLAY_DIR"/ "$CHROOT"/
}

unmount_chroot() {
    log "Unmounting chroot virtual filesystems"
    rm -f "$CHROOT/etc/resolv.conf"
    for m in dev/pts dev proc sys run; do
        mountpoint -q "$CHROOT/$m" && umount -lf "$CHROOT/$m" || true
    done
    MOUNTED=0
}

build_squashfs() {
    log "Squashing filesystem"
    mkdir -p "$ISO/live"
    mksquashfs "$CHROOT" "$ISO/live/filesystem.squashfs" \
        -comp xz -Xbcj x86 -b 1M -e boot -noappend -no-xattrs

    local vmlinuz_file
    local initrd_file

    vmlinuz_file="$(ls -t "$CHROOT"/boot/vmlinuz-* 2>/dev/null | head -n1 || true)"
    initrd_file="$(ls -t "$CHROOT"/boot/initrd.img-* 2>/dev/null | head -n1 || true)"

    [ -n "$vmlinuz_file" ] && [ -f "$vmlinuz_file" ] || die "No vmlinuz kernel found in $CHROOT/boot"
    [ -n "$initrd_file" ] && [ -f "$initrd_file" ] || die "No initrd image found in $CHROOT/boot"

    log "Copying kernel ($vmlinuz_file) and initrd ($initrd_file) to ISO..."
    cp "$vmlinuz_file" "$ISO/live/vmlinuz"
    cp "$initrd_file" "$ISO/live/initrd"
}

build_bootloaders() {
    # Kernel arguments shared by every boot entry
    local args="boot=live"
    [ "$CONSOLE_NOMODESET" = "1" ] && args="$args nomodeset"

    log "Setting up isolinux (BIOS)"
    mkdir -p "$ISO/isolinux"
    cp /usr/lib/ISOLINUX/isolinux.bin "$ISO/isolinux/"
    cp /usr/lib/syslinux/modules/bios/{ldlinux,libcom32,libutil,menu}.c32 "$ISO/isolinux/"

    {
        echo "UI menu.c32"
        if [ "$ENABLE_TORAM" = "1" ]; then echo "DEFAULT live-toram"; else echo "DEFAULT live"; fi
        echo "TIMEOUT 50"
        echo "PROMPT 0"
        if [ "$ENABLE_TORAM" = "1" ]; then
            cat <<EOF

LABEL live-toram
  MENU LABEL Boot ${HOSTNAME} (copy to RAM)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd $args toram
EOF
        fi
        cat <<EOF

LABEL live
  MENU LABEL Boot ${HOSTNAME}$([ "$ENABLE_TORAM" = "1" ] && echo " (no RAM disk / low memory)")
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd $args
EOF
    } > "$ISO/isolinux/isolinux.cfg"

    log "Setting up GRUB (UEFI)"
    mkdir -p "$ISO/EFI/boot" "$ISO/boot/grub"

    {
        cat <<EOF
set timeout=5
insmod part_gpt
insmod part_msdos
insmod iso9660
insmod search
search --no-floppy --set=root --file /live/filesystem.squashfs
EOF
        if [ "$ENABLE_TORAM" = "1" ]; then
            cat <<EOF
menuentry "Boot ${HOSTNAME} (copy to RAM)" {
    linux (\$root)/live/vmlinuz $args toram
    initrd (\$root)/live/initrd
}
menuentry "Boot ${HOSTNAME} (no RAM disk / low memory)" {
    linux (\$root)/live/vmlinuz $args
    initrd (\$root)/live/initrd
}
EOF
        else
            cat <<EOF
menuentry "Boot ${HOSTNAME}" {
    linux (\$root)/live/vmlinuz $args
    initrd (\$root)/live/initrd
}
EOF
        fi
    } > "$ISO/boot/grub/grub.cfg"

    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$ISO/EFI/boot/bootx64.efi" \
        --locales="" --fonts="" \
        --modules="part_gpt part_msdos iso9660 search normal linux" \
        "boot/grub/grub.cfg=$ISO/boot/grub/grub.cfg"

    dd if=/dev/zero of="$ISO/efiboot.img" bs=1M count=10 status=none
    mkfs.vfat "$ISO/efiboot.img" >/dev/null
    mmd -i "$ISO/efiboot.img" ::EFI ::EFI/boot
    mcopy -i "$ISO/efiboot.img" "$ISO/EFI/boot/bootx64.efi" ::EFI/boot/bootx64.efi
}

build_iso() {
    log "Assembling hybrid ISO with xorriso"
    ( cd "$ISO" && xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "${HOSTNAME^^}" \
        -eltorito-boot isolinux/isolinux.bin \
            -no-emul-boot -boot-load-size 4 -boot-info-table \
            -eltorito-catalog isolinux/boot.cat \
        -eltorito-alt-boot \
            -e efiboot.img -no-emul-boot -isohybrid-gpt-basdat \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "$OUT" \
        . )
    log "Done: $OUT ($(du -h "$OUT" | cut -f1))"
}

# ===================== BUNDLE THE INSTALLER INTO THE ISO ====================
# Rolls install-cephalo.sh plus the selected custom kernel into the live
# image, and adds the `cephalo-install` launcher + desktop entry.
stage_installer_payload() {
    log "Rolling the Cephalo installer and kernel payload into the image"
    local dest="$CHROOT$PAYLOAD_DIR"
    mkdir -p "$dest/kernel" "$CHROOT/usr/local/bin"

    install -m 0755 "$INSTALLER_SRC" "$dest/install-cephalo.sh"
    cp -a "$KERNEL_SRC"/. "$dest/kernel/"

    cat > "$CHROOT/usr/local/bin/cephalo-install" <<EOF
#!/bin/sh
# Launch the Cephalo installer.
exec $PAYLOAD_DIR/install-cephalo.sh "\$@"
EOF
    chmod 0755 "$CHROOT/usr/local/bin/cephalo-install"
}

# ================================ BUILD =====================================
build_main() {
    require_root
    [ -f "$INSTALLER_SRC" ] || die "Installer script not found: $INSTALLER_SRC (set INSTALLER_SRC, or put install-cephalo.sh next to this script)"

    log "Build directory: $WORK  (running as root, invoked by: $REAL_USER)"
    install_host_deps
    debootstrap_base
    mount_chroot
    prepare_custom_kernel
    write_chroot_script
    run_chroot_setup
    stage_installer_payload
    apply_overlay
    unmount_chroot
    build_squashfs
    build_bootloaders
    build_iso
}

usage() {
    sed -n '2,/^set -euo/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-build}" in
    build)           build_main ;;
    -h|--help|help)  usage ;;
    *)               usage >&2; die "unknown argument: $1 (this script takes no arguments; the installer is install-cephalo.sh)" ;;
esac
