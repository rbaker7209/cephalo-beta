#!/usr/bin/env bash
#
# install-cephalo.sh — the Cephalo installer.
#
# Installs Cephalo (Debian Trixie + labwc, custom kernel, Firefox ESR, zRAM,
# full Bluetooth + PipeWire audio stack with a Waybar Bluetooth manager)
# onto a disk. It is rolled into the minimal live ISO by build-cephalo-iso.sh under
# /opt/cephalo and launched with the `cephalo-install` command.
#
# It shows a disk selection menu, partitions the chosen disk (GPT, bootable
# on both BIOS and UEFI), debootstraps the system onto it, and installs GRUB.
# The custom kernel is taken from the copy bundled in the ISO.
#
# Run as root inside the live session; a network connection is required.
#
# Usage:
#   cephalo-install
#
# Optional presets (skip the matching prompt): INSTALL_DISK, INSTALL_HOSTNAME,
# INSTALL_USER, INSTALL_PASS, INSTALL_YES=1 (skip the final erase confirmation).

set -euo pipefail

# ============================== CONFIG =====================================

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

DEBIAN_MIRROR="http://deb.debian.org/debian"
SUITE="trixie"

LOCALE="en_US.UTF-8"
KEYBOARD_LAYOUT="us"
TIMEZONE="${TIMEZONE:-UTC}"

# --- Hardware-compatibility toggles ---------------------------------------
INCLUDE_BROADCOM_STA="${INCLUDE_BROADCOM_STA:-1}"
INCLUDE_NVIDIA_DRIVER="${INCLUDE_NVIDIA_DRIVER:-0}"

# NOTE: these package sets describe the INSTALLED system (full labwc desktop).
# The live installer ISO is a separate, minimal command-line image defined in
# build-cephalo-iso.sh, so the two no longer need to be kept in sync.
# Package sets — added zstd and kmod for initramfs generation
BASE_PKGS="locales console-setup keyboard-configuration sudo systemd-sysv network-manager wpasupplicant firmware-linux-free initramfs-tools zstd kmod"

DISPLAY_PKGS="xserver-xorg xserver-xorg-legacy xserver-xorg-video-all xserver-xorg-input-all lightdm lightdm-gtk-greeter"
LABWC_PKGS="labwc xwayland thunar xfce4-power-manager"
LABWC_EXTRA_PKGS="waybar wofi foot mako-notifier swaybg swaylock mate-polkit papirus-icon-theme arc-theme fonts-noto fonts-noto-color-emoji fonts-font-awesome network-manager-gnome imagemagick"

EXTRA_PKGS="firefox-esr file-roller zram-tools"

# --- Bluetooth + audio stack ----------------------------------------------
# CORE packages must install (the build aborts otherwise) so we never ship a
# system with silently broken Bluetooth. EXTRA ones are nice-to-have.
BT_CORE_PKGS="bluez rfkill dbus-user-session libpam-systemd pipewire pipewire-alsa pipewire-pulse wireplumber libspa-0.2-bluetooth blueman"
BT_EXTRA_PKGS="bluez-obexd rtkit alsa-utils pulseaudio-utils pavucontrol libnotify-bin gir1.2-notify-0.7 playerctl"

# Kernel options the custom kernel needs for Bluetooth to work (checked, not enforced)
BT_KERNEL_REQUIRED="BT BT_BREDR BT_LE BT_RFCOMM BT_BNEP BT_HIDP BT_HCIBTUSB UHID INPUT_UINPUT RFKILL CRYPTO_USER_API_HASH CRYPTO_USER_API_SKCIPHER CRYPTO_CMAC CRYPTO_ECB CRYPTO_ECDH"
BT_KERNEL_RECOMMENDED="BT_INTEL BT_BCM BT_RTL BT_MTK BT_QCA BT_HCIBTUSB_BCM BT_HCIBTUSB_RTL BT_HCIBTUSB_MTK BT_HCIUART BT_HCIBTSDIO HIDRAW HID_GENERIC HID_BATTERY_STRENGTH"

MICROCODE_PKGS="intel-microcode amd64-microcode"
FIRMWARE_CORE_PKGS="firmware-misc-nonfree firmware-realtek firmware-atheros firmware-iwlwifi firmware-brcm80211 firmware-amd-graphics firmware-nvidia-graphics pciutils usbutils fwupd"
FIRMWARE_EXTRA_PKGS="firmware-ath9k-htc firmware-libertas firmware-ralink firmware-mediatek firmware-sof-signed firmware-intel-sound firmware-intel-misc"
DKMS_PKGS="build-essential dkms"
BROADCOM_STA_PKGS="broadcom-sta-dkms"
NVIDIA_PKGS="nvidia-driver nvidia-detect"

# Bootloader packages installed into the *target* system:
BOOT_PKGS="grub2-common grub-pc-bin grub-efi-amd64-bin efibootmgr"

PAYLOAD_DIR="/opt/cephalo"                      # where the installer + kernel live inside the ISO
INSTALL_MNT="${INSTALL_MNT:-/mnt/cephalo-target}"
CHROOT="$INSTALL_MNT"
INSTALL_HOSTNAME_DEFAULT="cephalo"
ESP_SIZE_MIB=512

# =========================== END CONFIG =====================================

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$1"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run this as root (sudo)."; }

KERNEL_SRC=""
BOOT_MODE="bios"

MOUNTED=0
TARGET_MOUNTED=0
cleanup() {
    if [ "$MOUNTED" -eq 1 ]; then
        log "Cleaning up chroot mounts"
        for m in sys/firmware/efi/efivars dev/pts dev proc sys run; do
            mountpoint -q "$CHROOT/$m" && umount -lf "$CHROOT/$m" || true
        done
        MOUNTED=0
    fi
    if [ "$TARGET_MOUNTED" -eq 1 ]; then
        log "Unmounting target disk"
        sync
        umount -R "$INSTALL_MNT" 2>/dev/null || umount -Rl "$INSTALL_MNT" || true
        TARGET_MOUNTED=0
    fi
}
trap cleanup EXIT INT TERM

prepare_custom_kernel() {
    # Use the kernel that was rolled into the live ISO.
    KERNEL_SRC="$PAYLOAD_DIR/kernel"
    [ -d "$KERNEL_SRC" ] || die "Bundled kernel not found at $KERNEL_SRC (is this the Cephalo live ISO?)"
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
    # On a UEFI machine, expose efivars so grub-install can add a boot entry
    if [ -d /sys/firmware/efi/efivars ] && [ -d "$CHROOT/sys/firmware/efi/efivars" ]; then
        mount --bind /sys/firmware/efi/efivars "$CHROOT/sys/firmware/efi/efivars" || true
    fi
    cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
    MOUNTED=1
}

write_chroot_script() {
    log "Writing in-chroot setup script"


    cat > "$CHROOT/root/setup.sh" <<CHROOTEOF
#!/usr/bin/env bash
set -euo pipefail

echo 'APT::Install-Recommends "0";' > /etc/apt/apt.conf.d/99no-recommends

cat > /etc/apt/sources.list <<EOF
deb $DEBIAN_MIRROR $SUITE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $SUITE-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $SUITE-security main contrib non-free non-free-firmware
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update

# locales / keyboard / hostname
apt-get install -y $BASE_PKGS
sed -i "s/^# *${LOCALE//./\\.} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG=${LOCALE}
echo "$INSTALL_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $INSTALL_HOSTNAME
EOF

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

# --- Broad hardware enablement: CPU microcode + firmware blobs -----------
FAILED_UCODE=""
for pkg in $MICROCODE_PKGS; do
    apt-get install -y "\$pkg" || FAILED_UCODE="\$FAILED_UCODE \$pkg"
done
[ -n "\$FAILED_UCODE" ] && echo "WARNING: failed to install:\$FAILED_UCODE" >&2

FAILED_FW=""
for pkg in $FIRMWARE_CORE_PKGS $FIRMWARE_EXTRA_PKGS; do
    apt-get install -y "\$pkg" || FAILED_FW="\$FAILED_FW \$pkg"
done
[ -n "\$FAILED_FW" ] && echo "WARNING: failed to install:\$FAILED_FW (continuing without them)" >&2

for fwdir in amdgpu radeon brcm iwlwifi ; do
    if [ -d "/lib/firmware/\$fwdir" ] && [ -n "\$(ls -A "/lib/firmware/\$fwdir" 2>/dev/null)" ]; then
        FWCOUNT=\$(ls -1 "/lib/firmware/\$fwdir" | wc -l)
        echo "firmware check: /lib/firmware/\$fwdir populated (\$FWCOUNT files)"
    else
        echo "WARNING: /lib/firmware/\$fwdir is missing or empty — matching hardware will fail to init" >&2
    fi
done

apt-get install -y $DKMS_PKGS

if [ "$INCLUDE_BROADCOM_STA" = "1" ]; then
    echo "Attempting Broadcom STA driver installation..."
    if ! apt-get install -y $BROADCOM_STA_PKGS; then
        echo "WARNING: broadcom-sta-dkms failed to install/build (missing custom kernel headers). Purging package to unblock package manager..." >&2
        apt-get purge -y $BROADCOM_STA_PKGS || true
        BCM_BLACKLIST_FILES=\$(dpkg -L broadcom-sta-dkms 2>/dev/null | grep '^/etc/modprobe\.d/' || true)
        if [ -n "\$BCM_BLACKLIST_FILES" ]; then
            rm -f \$BCM_BLACKLIST_FILES
        fi
    fi
fi

if [ "$INCLUDE_NVIDIA_DRIVER" = "1" ]; then
    echo "Attempting NVIDIA driver installation..."
    if ! apt-get install -y $NVIDIA_PKGS; then
        echo "WARNING: nvidia-driver failed to install. Purging package to unblock package manager..." >&2
        apt-get purge -y $NVIDIA_PKGS || true
    fi
fi

# Display manager (X greeter) + labwc (Wayland session)
apt-get install -y $DISPLAY_PKGS
apt-get install -y $LABWC_PKGS

FAILED_EXTRAS=""
for pkg in $LABWC_EXTRA_PKGS; do
    apt-get install -y "\$pkg" || FAILED_EXTRAS="\$FAILED_EXTRAS \$pkg"
done
if [ -n "\$FAILED_EXTRAS" ]; then
    echo "WARNING: failed to install:\$FAILED_EXTRAS (continuing without them)" >&2
fi


# extras (includes firefox-esr and zram-tools)
apt-get install -y $EXTRA_PKGS || true

# --- Bluetooth + audio stack (core must succeed) ---
apt-get install -y $BT_CORE_PKGS
FAILED_BT=""
for pkg in $BT_EXTRA_PKGS; do
    apt-get install -y "\$pkg" || FAILED_BT="\$FAILED_BT \$pkg"
done
[ -n "\$FAILED_BT" ] && echo "WARNING: failed to install optional Bluetooth/audio packages:\$FAILED_BT" >&2

# --- Performance & Disk Optimization ---
cat > /etc/sysctl.d/99-disk-optimization.conf <<EOF
vm.swappiness=10
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.vfs_cache_pressure=50
EOF

# --- zRAM Configuration ---
if [ -f /etc/default/zramswap ]; then
    cat > /etc/default/zramswap <<EOF
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
fi

# --- labwc desktop configuration ---
mkdir -p /usr/share/backgrounds
if command -v convert >/dev/null 2>&1; then
    convert -size 1920x1080 gradient:'#1e1e2e-#313244' /usr/share/backgrounds/cephalo-gradient.png || true
fi

mkdir -p /etc/skel/.config/labwc /etc/skel/.config/waybar /etc/skel/.config/mako \
         /etc/skel/.config/gtk-3.0

cat > /etc/skel/.config/labwc/autostart <<'EOF'
#!/bin/sh
exec >>"\$HOME/.labwc-autostart.log" 2>&1
echo "=== autostart run: \$(date) ==="

# Import the session environment into the systemd/dbus user managers, then make
# sure the audio stack is up so Bluetooth audio devices are handled right away.
command -v dbus-update-activation-environment >/dev/null 2>&1 && \\
    dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP DISPLAY
command -v systemctl >/dev/null 2>&1 && \\
    systemctl --user --no-block start pipewire.service wireplumber.service pipewire-pulse.service

if [ -f /usr/share/backgrounds/cephalo-gradient.png ] && command -v swaybg >/dev/null 2>&1; then
    swaybg -i /usr/share/backgrounds/cephalo-gradient.png -m fill &
elif command -v swaybg >/dev/null 2>&1; then
    swaybg -c 1e1e2e &
fi

command -v waybar >/dev/null 2>&1 && waybar &
command -v mako >/dev/null 2>&1 && mako &

for agent in \
    /usr/lib/mate-polkit/polkit-mate-authentication-agent-1 \
    /usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1 \
    /usr/lib/x86_64-linux-gnu/libexec/polkit-kde-authentication-agent-1 \
    /usr/lib/policykit-1-kde/polkit-kde-authentication-agent-1 \
    /usr/lib/lxqt-policykit/lxqt-policykit-agent \
    /usr/bin/lxpolkit
do
    if [ -x "\$agent" ]; then
        "\$agent" &
        break
    fi
done

command -v nm-applet >/dev/null 2>&1 && nm-applet --indicator &
# Blueman applet = Bluetooth pairing agent (PIN / passkey prompts) + notifications
command -v blueman-applet >/dev/null 2>&1 && blueman-applet &
command -v xfce4-power-manager >/dev/null 2>&1 && xfce4-power-manager &
EOF
chmod +x /etc/skel/.config/labwc/autostart

cat > /etc/skel/.config/labwc/environment <<'EOF'
XCURSOR_THEME=Adwaita
XCURSOR_SIZE=24
GTK_THEME=Arc-Dark
QT_QPA_PLATFORMTHEME=gtk3
EOF

cat > /etc/skel/.config/labwc/rc.xml <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <theme>
    <name>Arc-Dark</name>
    <cornerRadius>8</cornerRadius>
    <font place="ActiveWindow">
      <name>Sans</name>
      <size>10</size>
    </font>
  </theme>
  <keyboard>
    <keybind key="W-Return"><action name="Execute" command="foot"/></keybind>
    <keybind key="W-d"><action name="Execute" command="wofi --show drun"/></keybind>
    <keybind key="W-e"><action name="Execute" command="thunar"/></keybind>
    <keybind key="W-q"><action name="Close"/></keybind>
    <keybind key="A-Tab"><action name="NextWindow"/></keybind>
    <keybind key="W-b"><action name="Execute" command="cephalo-bt-menu"/></keybind>
    <keybind key="XF86AudioRaiseVolume"><action name="Execute" command="wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"/></keybind>
    <keybind key="XF86AudioLowerVolume"><action name="Execute" command="wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"/></keybind>
    <keybind key="XF86AudioMute"><action name="Execute" command="wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"/></keybind>
    <keybind key="XF86AudioMicMute"><action name="Execute" command="wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"/></keybind>
    <keybind key="XF86AudioPlay"><action name="Execute" command="playerctl play-pause"/></keybind>
    <keybind key="XF86AudioPause"><action name="Execute" command="playerctl pause"/></keybind>
    <keybind key="XF86AudioNext"><action name="Execute" command="playerctl next"/></keybind>
    <keybind key="XF86AudioPrev"><action name="Execute" command="playerctl previous"/></keybind>
  </keyboard>
</labwc_config>
EOF

cat > /etc/skel/.config/labwc/menu.xml <<'EOF'
<?xml version="1.0"?>
<openbox_menu>
  <menu id="root-menu" label="Cephalo">
    <item label="Terminal"><action name="Execute"><command>foot</command></action></item>
    <item label="Files"><action name="Execute"><command>thunar</command></action></item>
    <item label="Web Browser"><action name="Execute"><command>firefox-esr</command></action></item>
    <item label="App Launcher"><action name="Execute"><command>wofi --show drun</command></action></item>
    <separator/>
    <item label="Lock Screen"><action name="Execute"><command>swaylock -f -c 1e1e2e</command></action></item>
    <item label="Power Off"><action name="Execute"><command>systemctl poweroff</command></action></item>
  </menu>
</openbox_menu>
EOF

cat > /etc/skel/.config/waybar/config <<'EOF'
{
    "layer": "top",
    "position": "top",
    "height": 32,
    "modules-left": ["custom/launcher"],
    "modules-center": ["clock"],
    "modules-right": ["pulseaudio", "custom/bluetooth", "network", "cpu", "memory", "tray"],
    "custom/launcher": {
        "format": "Apps",
        "on-click": "wofi --show drun",
        "tooltip": false
    },
    "clock": {
        "format": "{:%a %d %b  %H:%M}"
    },
    "custom/bluetooth": {
        "exec": "cephalo-bt-status",
        "return-type": "json",
        "interval": 10,
        "signal": 8,
        "tooltip": true,
        "on-click": "cephalo-bt-menu",
        "on-click-right": "blueman-manager"
    },
    "pulseaudio": {
        "format": "Vol {volume}%",
        "format-muted": "Muted",
        "format-bluetooth": "BT Vol {volume}%",
        "format-bluetooth-muted": "BT Muted",
        "scroll-step": 5,
        "on-click": "pavucontrol",
        "on-click-right": "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
    },
    "network": {
        "format-wifi": "Wi-Fi: {essid}",
        "format-ethernet": "Wired: {ifname}",
        "format-disconnected": "Offline"
    },
    "cpu": {
        "format": "CPU {usage}%"
    },
    "memory": {
        "format": "Mem {}%"
    },
    "tray": {
        "spacing": 8
    }
}
EOF

cat > /etc/skel/.config/waybar/style.css <<'EOF'
* {
    font-family: "Noto Sans", "FontAwesome", sans-serif;
    font-size: 13px;
}
window#waybar {
    background-color: rgba(30, 30, 46, 0.9);
    color: #cdd6f4;
}
#custom-launcher, #clock, #network, #cpu, #memory, #tray, #pulseaudio, #custom-bluetooth {
    padding: 0 10px;
}
#custom-launcher {
    color: #89b4fa;
    font-weight: bold;
}
#custom-bluetooth.off, #custom-bluetooth.missing {
    color: #6c7086;
}
#custom-bluetooth.connected {
    color: #89b4fa;
}
#custom-bluetooth.low {
    color: #f9e2af;
}
#custom-bluetooth.critical {
    color: #f38ba8;
}
#pulseaudio.muted {
    color: #6c7086;
}
EOF

cat > /etc/skel/.config/mako/config <<'EOF'
background-color=#1e1e2eee
text-color=#cdd6f4
border-color=#89b4fa
border-radius=8
border-size=2
default-timeout=5000
font=Noto Sans 10
EOF

cat > /etc/skel/.config/gtk-3.0/settings.ini <<'EOF'
[Settings]
gtk-theme-name=Arc-Dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Noto Sans 10
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
gtk-application-prefer-dark-theme=1
EOF

mkdir -p /etc/lightdm/lightdm.conf.d
# installed system: normal greeter login, labwc session
# (the real user + passwords are created by the installer after this script)
cat > /etc/lightdm/lightdm.conf.d/50-session.conf <<EOF
[Seat:*]
user-session=labwc
EOF
# --- Force Initramfs Creation for Custom Kernels ---
if [ -d /lib/modules ]; then
    for kvers in \$(ls /lib/modules); do
        echo "Generating initramfs for kernel version: \$kvers"
        depmod -a "\$kvers" || true
        update-initramfs -c -k "\$kvers" || update-initramfs -u -k "\$kvers" || true
    done
fi

# Timezone + GRUB packages. GRUB goes in *after* the
# kernel/initramfs so kernel hooks don't try to run update-grub too early;
# the installer runs grub-install / update-grub itself afterwards.
apt-get install -y tzdata
TZNAME="$TIMEZONE"
[ -f "/usr/share/zoneinfo/\$TZNAME" ] || TZNAME=UTC
echo "\$TZNAME" > /etc/timezone
ln -sf "/usr/share/zoneinfo/\$TZNAME" /etc/localtime
dpkg-reconfigure -f noninteractive tzdata || true

apt-get install -y $BOOT_PKGS

systemctl enable lightdm.service
systemctl set-default graphical.target

apt-get clean
rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/*
CHROOTEOF
    chmod +x "$CHROOT/root/setup.sh"
}

run_chroot_setup() {
    log "Running setup inside chroot (this is the long step)"
    chroot "$CHROOT" /root/setup.sh
    rm -f "$CHROOT/root/setup.sh"
}

unmount_chroot() {
    log "Unmounting chroot virtual filesystems"
    rm -f "$CHROOT/etc/resolv.conf"
    for m in sys/firmware/efi/efivars dev/pts dev proc sys run; do
        mountpoint -q "$CHROOT/$m" && umount -lf "$CHROOT/$m" || true
    done
    MOUNTED=0
}

INSTALL_DISK="${INSTALL_DISK:-}"
INSTALL_HOSTNAME="${INSTALL_HOSTNAME:-}"
INSTALL_USER="${INSTALL_USER:-}"
INSTALL_PASS="${INSTALL_PASS:-}"
ROOT_PART=""
ESP_PART=""
UI_TITLE="Cephalo Installer"

# whiptail wrapper: result comes back on stdout; non-zero return = cancelled
ui()     { whiptail --title "$UI_TITLE" "$@" 3>&1 1>&2 2>&3; }
ui_msg() { whiptail --title "$UI_TITLE" --msgbox "$1" 14 72; }

need_installer_tools() {
    local t missing=""
    for t in whiptail debootstrap parted wipefs lsblk blkid findmnt partprobe udevadm \
             mkfs.ext4 mkfs.vfat wget chroot; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    [ -z "$missing" ] || die "installer tools missing:$missing"
}

ensure_network() {
    local url="$DEBIAN_MIRROR/dists/$SUITE/InRelease"
    until wget -q --spider --timeout=8 --tries=1 "$url"; do
        if whiptail --title "$UI_TITLE" --yesno \
            "Cannot reach $DEBIAN_MIRROR.\n\nThe installer downloads Debian packages, so it needs a working network connection.\n\nOpen the network manager (nmtui) now?" 13 72; then
            nmtui || true
        else
            die "No network connection; cannot install."
        fi
    done
}

# Name (e.g. sdb) of the disk the live ISO booted from, so it is never offered
live_medium_disk() {
    local m src pk
    for m in /run/live/medium /usr/lib/live/mount/medium /lib/live/mount/medium; do
        if mountpoint -q "$m" 2>/dev/null; then
            src="$(findmnt -no SOURCE "$m" || true)"
            [ -n "$src" ] || continue
            pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
            echo "${pk:-$(basename "$src")}"
            return 0
        fi
    done
    return 0
}

select_disk() {
    if [ -n "$INSTALL_DISK" ]; then
        [ -b "$INSTALL_DISK" ] || die "INSTALL_DISK is not a block device: $INSTALL_DISK"
        return
    fi

    local live_disk dev size model
    local -a entries=()
    live_disk="$(live_medium_disk)"

    while read -r dev; do
        [ -n "$dev" ] || continue
        [ "$(basename "$dev")" = "$live_disk" ] && continue
        size="$(lsblk -dno SIZE "$dev" 2>/dev/null | tr -d ' ')"
        [ -n "$size" ] && [ "$size" != "0B" ] || continue
        model="$(lsblk -dno MODEL "$dev" 2>/dev/null | sed 's/ *$//')"
        entries+=("$dev" "$size  ${model:-unknown model}")
    done < <(lsblk -dnpo NAME,TYPE | awk '$2=="disk" && $1 !~ /\/(zram|ram|nbd|loop|fd)[0-9]*$/ {print $1}')

    [ "${#entries[@]}" -gt 0 ] || die "No installable disks found."

    INSTALL_DISK="$(ui --menu \
        "Select the disk to install Cephalo on.\n\nTHE ENTIRE DISK WILL BE ERASED." \
        20 74 8 "${entries[@]}")" || die "Installation cancelled."
}

prompt_system_settings() {
    local p1 p2

    while ! [[ "$INSTALL_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; do
        [ -z "$INSTALL_HOSTNAME" ] || ui_msg "Invalid hostname. Use letters, digits and '-' (not at the start or end)."
        INSTALL_HOSTNAME="$(ui --inputbox "Hostname for the new system:" 10 60 \
            "$INSTALL_HOSTNAME_DEFAULT")" || die "Installation cancelled."
    done

    while ! [[ "$INSTALL_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; do
        [ -z "$INSTALL_USER" ] || ui_msg "Invalid username. Use lowercase letters, digits, '_' or '-', starting with a letter."
        INSTALL_USER="$(ui --inputbox "Username for the new system:" 10 60)" || die "Installation cancelled."
    done

    while [ -z "$INSTALL_PASS" ]; do
        p1="$(ui --passwordbox "Password for $INSTALL_USER:" 10 60)" || die "Installation cancelled."
        p2="$(ui --passwordbox "Confirm password:" 10 60)" || die "Installation cancelled."
        if [ -z "$p1" ]; then
            ui_msg "Password must not be empty."
        elif [ "$p1" != "$p2" ]; then
            ui_msg "Passwords do not match."
        else
            INSTALL_PASS="$p1"
        fi
    done
}

confirm_erase() {
    [ "${INSTALL_YES:-0}" = "1" ] && return 0
    local summary
    summary="$(lsblk -po NAME,SIZE,FSTYPE,LABEL "$INSTALL_DISK" 2>/dev/null || true)"
    whiptail --title "$UI_TITLE" --defaultno --yesno \
"ALL DATA on $INSTALL_DISK will be permanently destroyed:

$summary

Boot mode:  $BOOT_MODE
Hostname:   $INSTALL_HOSTNAME
User:       $INSTALL_USER

Erase the disk and install Cephalo?" 22 76 || die "Installation cancelled."
}

# /dev/sda + 3 -> /dev/sda3 ; /dev/nvme0n1 + 3 -> /dev/nvme0n1p3
part_path() {
    case "$1" in
        *[0-9]) echo "${1}p$2" ;;
        *)      echo "${1}$2" ;;
    esac
}

# GPT layout that boots on both BIOS and UEFI machines:
#   1: 1 MiB bios_grub   2: ESP (FAT32)   3: root (ext4, rest of disk)
partition_disk() {
    local d="$INSTALL_DISK" p i
    log "Partitioning $d"

    # Release anything on the disk that is still mounted / used as swap
    for p in $(lsblk -lnpo NAME "$d" | tail -n +2 | tac); do
        umount "$p" 2>/dev/null || true
        swapoff "$p" 2>/dev/null || true
    done

    wipefs -af "$d" >/dev/null
    parted -s "$d" -- \
        mklabel gpt \
        mkpart biosboot 1MiB 2MiB \
        set 1 bios_grub on \
        mkpart ESP fat32 2MiB "$((2 + ESP_SIZE_MIB))MiB" \
        set 2 esp on \
        mkpart cephalo-root ext4 "$((2 + ESP_SIZE_MIB))MiB" 100%

    partprobe "$d" || true
    udevadm settle || true

    ESP_PART="$(part_path "$d" 2)"
    ROOT_PART="$(part_path "$d" 3)"
    for i in $(seq 1 30); do
        [ -b "$ESP_PART" ] && [ -b "$ROOT_PART" ] && break
        sleep 0.5
    done
    [ -b "$ROOT_PART" ] || die "Partition $ROOT_PART did not appear after partitioning."

    log "Creating filesystems"
    mkfs.vfat -F32 -n CEPHALOESP "$ESP_PART" >/dev/null
    mkfs.ext4 -F -q -L cephalo-root "$ROOT_PART"
}

mount_target_root() {
    mkdir -p "$INSTALL_MNT"
    mount "$ROOT_PART" "$INSTALL_MNT"
    TARGET_MOUNTED=1
}

mount_target_esp() {
    mkdir -p "$CHROOT/boot/efi"
    mount "$ESP_PART" "$CHROOT/boot/efi"
}

write_fstab() {
    local root_uuid esp_uuid
    root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
    esp_uuid="$(blkid -s UUID -o value "$ESP_PART")"
    cat > "$CHROOT/etc/fstab" <<EOF
# /etc/fstab — generated by the Cephalo installer
UUID=$root_uuid  /          ext4  defaults,noatime,errors=remount-ro  0  1
UUID=$esp_uuid   /boot/efi  vfat  umask=0077                          0  2
EOF
}

configure_target_users() {
    local g
    log "Creating user '$INSTALL_USER'"
    chroot "$CHROOT" adduser --disabled-password --gecos "" "$INSTALL_USER"
    chroot "$CHROOT" adduser "$INSTALL_USER" sudo
    for g in audio video render input netdev plugdev cdrom bluetooth lp; do
        if chroot "$CHROOT" getent group "$g" >/dev/null 2>&1; then
            chroot "$CHROOT" adduser "$INSTALL_USER" "$g" >/dev/null 2>&1 || true
        fi
    done
    # password goes over stdin so it never touches a script or the process list
    printf '%s:%s\n' "$INSTALL_USER" "$INSTALL_PASS" | chroot "$CHROOT" chpasswd
    chroot "$CHROOT" passwd -l root >/dev/null
}

install_bootloader() {
    log "Installing GRUB ($BOOT_MODE)"
    if [ "$BOOT_MODE" = "uefi" ]; then
        chroot "$CHROOT" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
            --bootloader-id=Cephalo --recheck \
            || echo "WARNING: could not create a UEFI boot entry; relying on the removable fallback." >&2
        # Fallback path (EFI/BOOT/BOOTX64.EFI) so firmware without our NVRAM entry still boots
        chroot "$CHROOT" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
            --removable --recheck \
            || die "grub-install (UEFI removable) failed"
    else
        chroot "$CHROOT" grub-install --target=i386-pc --recheck "$INSTALL_DISK" \
            || die "grub-install (BIOS) failed"
    fi

    chroot "$CHROOT" update-grub

    ls "$CHROOT"/boot/vmlinuz-* >/dev/null 2>&1 || die "No kernel found in the installed system's /boot"
    grep -q '^menuentry' "$CHROOT/boot/grub/grub.cfg" || die "grub.cfg has no boot entries"
}

# ---------------------------------------------------------------------------
# Bluetooth: configuration, helper scripts, Waybar integration, kernel check
# ---------------------------------------------------------------------------

# put MODE DEST < content   (creates parent dirs)
put() { local mode="$1" dest="$2"; mkdir -p "$(dirname "$dest")"; cat > "$dest"; chmod "$mode" "$dest"; }

configure_bluetooth() {
    log "Configuring Bluetooth + audio"

    # bluetoothd: experimental mode exposes battery reporting for headsets
    # (HFP/AVRCP) through BlueZ. A drop-in keeps /etc/bluetooth/main.conf pristine.
    local btd
    btd="$(chroot "$CHROOT" sh -c 'ls /usr/libexec/bluetooth/bluetoothd /usr/lib/bluetooth/bluetoothd 2>/dev/null | head -n1' || true)"
    [ -n "$btd" ] || die "bluetoothd binary not found in the target system (bluez failed to install?)"
    put 644 "$CHROOT/etc/systemd/system/bluetooth.service.d/10-cephalo.conf" <<EOF
[Service]
ExecStart=
ExecStart=$btd -E
EOF

    # Kernel modules the BlueZ HID/audio/serial profiles rely on. Modules that
    # are built in or absent are harmless here.
    put 644 "$CHROOT/etc/modules-load.d/cephalo-bluetooth.conf" <<'EOF'
# Loaded at boot so keyboards, mice, gamepads and headsets work immediately.
btusb
uhid
uinput
hidp
rfcomm
bnep
EOF

    # WirePlumber (0.5+): better-sounding SBC, wideband mic on headsets, HW volume
    put 644 "$CHROOT/etc/wireplumber/wireplumber.conf.d/51-cephalo-bluez.conf" <<'EOF'
monitor.bluez.properties = {
    bluez5.enable-sbc-xq    = true
    bluez5.enable-msbc      = true
    bluez5.enable-hw-volume = true
}
EOF

    # Make sure the audio stack + media-key forwarding start for every user session
    chroot "$CHROOT" systemctl enable bluetooth.service || echo "WARNING: could not enable bluetooth.service" >&2
    chroot "$CHROOT" systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service \
        || echo "WARNING: could not globally enable PipeWire user units" >&2
    chroot "$CHROOT" systemctl --global enable mpris-proxy.service >/dev/null 2>&1 || true

    # ---- shared helper library -------------------------------------------
    put 644 "$CHROOT/usr/local/lib/cephalo/bt-lib.sh" <<'EOF'
# shellcheck shell=bash
# Shared helpers for cephalo-bt-status / cephalo-bt-menu / cephalo-bt-doctor.

bt_have_controller() { bluetoothctl show 2>/dev/null | grep -q '^Controller'; }

bt_powered() {
    [ "$(bluetoothctl show 2>/dev/null | awk '/^[[:space:]]*Powered:/ {print $2; exit}')" = "yes" ]
}

# bt_list [Paired|Connected|Bonded|Trusted]  ->  "MAC<TAB>Name" per line
bt_list() {
    bluetoothctl devices "$@" 2>/dev/null |
        sed -n 's/^Device \(\([0-9A-Fa-f]\{2\}:\)\{5\}[0-9A-Fa-f]\{2\}\) \(.*\)$/\1\t\3/p'
}

# bt_field MAC Key   (e.g. Alias, Paired, Connected, Trusted)
bt_field() {
    bluetoothctl info "$1" 2>/dev/null | sed -n "s/^[[:space:]]*$2: //p" | head -n1
}

# bt_battery MAC -> percentage (empty if the device does not report one).
# Source 1: BlueZ Battery1 (GATT battery service, HFP/AVRCP headsets).
# Source 2: kernel HID battery (many mice/keyboards expose it only this way).
bt_battery() {
    local mac="$1" pct
    pct="$(bluetoothctl info "$mac" 2>/dev/null |
           sed -n 's/.*Battery Percentage:.*(\([0-9]\{1,3\}\)).*/\1/p' | head -n1)"
    if [ -z "$pct" ] && [ -r "/sys/class/power_supply/hid-${mac,,}-battery/capacity" ]; then
        pct="$(cat "/sys/class/power_supply/hid-${mac,,}-battery/capacity" 2>/dev/null)"
    fi
    printf '%s' "$pct"
}

bt_note() {
    command -v notify-send >/dev/null 2>&1 && notify-send -a Bluetooth -t 5000 "$1" "${2:-}"
    return 0
}

# Tell Waybar to refresh the Bluetooth module immediately (signal 8).
bt_poke_bar() { pkill -RTMIN+8 -x waybar 2>/dev/null; return 0; }
EOF

    # ---- Waybar module: status + per-device battery -----------------------
    put 755 "$CHROOT/usr/local/bin/cephalo-bt-status" <<'EOF'
#!/usr/bin/env bash
# Waybar custom module: prints one JSON line (text, tooltip, class).
. /usr/local/lib/cephalo/bt-lib.sh

ICON="$(printf '\xef\x8a\x93')"   # Font Awesome "bluetooth"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/cephalo-bt"
mkdir -p "$STATE_DIR" 2>/dev/null

# escape for Pango markup, then for JSON
esc() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
                           -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

emit() { printf '{"text":"%s","tooltip":"%s","class":%s}\n' "$1" "$2" "$3"; }

HINT='<i>Left-click: manage devices  |  Right-click: Blueman</i>'

if ! bt_have_controller; then
    emit "$ICON" "No Bluetooth adapter found\nRun cephalo-bt-doctor in a terminal" '["missing"]'
    exit 0
fi

if ! bt_powered; then
    emit "$ICON off" "Bluetooth is off\n$HINT" '["off"]'
    exit 0
fi

tip="<b>Connected devices</b>\n"
texts=()
count=0
lowest=101

while IFS=$'\t' read -r mac name; do
    [ -n "$mac" ] || continue
    count=$((count + 1))
    pct="$(bt_battery "$mac")"
    flag="$STATE_DIR/low-${mac//:/_}"
    if [[ "$pct" =~ ^[0-9]+$ ]]; then
        texts+=("${pct}%")
        tip+="$(esc "$name")  -  ${pct}%\n"
        [ "$pct" -lt "$lowest" ] && lowest="$pct"
        # one low-battery notification per discharge cycle
        if [ "$pct" -le 15 ] && [ ! -e "$flag" ]; then
            touch "$flag"
            command -v notify-send >/dev/null 2>&1 &&
                notify-send -a Bluetooth -u critical "Low battery" "$name is at ${pct}%"
        elif [ "$pct" -ge 25 ]; then
            rm -f "$flag"
        fi
    else
        tip+="$(esc "$name")  -  battery not reported\n"
    fi
done < <(bt_list Connected)

[ "$count" -gt 0 ] || tip="No devices connected\n"
tip+="$HINT"

text="$ICON"
if [ "${#texts[@]}" -gt 0 ]; then
    joined=""
    for t in "${texts[@]}"; do joined+="$t · "; done
    text="$ICON  ${joined% · }"
elif [ "$count" -gt 0 ]; then
    text="$ICON  $count"
fi

if [ "$count" -gt 0 ]; then
    classes='"connected"'
    [ "$lowest" -le 20 ] && classes+=',"low"'
    [ "$lowest" -le 10 ] && classes+=',"critical"'
else
    classes='"on"'
fi

emit "$text" "$tip" "[$classes]"
EOF

    # ---- wofi menu: scan / pair / connect / disconnect / forget -----------
    put 755 "$CHROOT/usr/local/bin/cephalo-bt-menu" <<'EOF'
#!/usr/bin/env bash
# Bluetooth manager driven by wofi. Bound to the Waybar module (click) and Super+B.
. /usr/local/lib/cephalo/bt-lib.sh

SCAN_SECONDS=10
WOFI=(wofi --dmenu --insensitive --cache-file /dev/null --width 560 --lines 14)

L_ON="Turn Bluetooth ON"
L_OFF="Turn Bluetooth OFF"
L_SCAN="Scan for new devices (${SCAN_SECONDS}s)"
L_ADV="Advanced settings (Blueman)"
L_NONE="(no devices yet - choose Scan, with your device in pairing mode)"

pick() { "${WOFI[@]}" --prompt "$1"; }

set_power() {
    if [ "$1" = on ]; then
        rfkill unblock bluetooth 2>/dev/null
        bluetoothctl power on >/dev/null 2>&1
    else
        bluetoothctl power off >/dev/null 2>&1
    fi
    sleep 0.5
    bt_poke_bar
}

# The pairing agent (PIN / passkey / confirmation dialogs) is blueman-applet.
ensure_agent() {
    if ! pgrep -f '[b]lueman-applet' >/dev/null 2>&1; then
        command -v blueman-applet >/dev/null 2>&1 || return 0
        setsid blueman-applet >/dev/null 2>&1 &
        sleep 3
    fi
}

do_scan() {
    bt_note "Scanning for ${SCAN_SECONDS} seconds" "Put your device into pairing mode now."
    bluetoothctl --timeout "$SCAN_SECONDS" scan on >/dev/null 2>&1
    bt_poke_bar
}

do_connect() {
    local mac="$1" name="$2"
    bt_note "Connecting to $name" "Please wait..."
    bluetoothctl trust "$mac" >/dev/null 2>&1
    timeout 30 bluetoothctl connect "$mac" >/dev/null 2>&1
    if [ "$(bt_field "$mac" Connected)" = yes ]; then
        bt_note "Connected" "$name"
    else
        bt_note "Could not connect to $name" "Check that it is switched on, in range and not connected to another device."
    fi
    bt_poke_bar
}

do_disconnect() {
    local mac="$1" name="$2"
    bluetoothctl disconnect "$mac" >/dev/null 2>&1
    bt_note "Disconnected" "$name"
    bt_poke_bar
}

do_forget() {
    local mac="$1" name="$2"
    bluetoothctl disconnect "$mac" >/dev/null 2>&1
    bluetoothctl remove "$mac" >/dev/null 2>&1
    bt_note "Removed" "$name"
    bt_poke_bar
}

do_pair() {
    local mac="$1" name="$2" path
    ensure_agent
    bluetoothctl pairable on >/dev/null 2>&1
    bt_note "Pairing with $name" "Accept the prompt if one appears. For keyboards, type the shown code on the keyboard and press Enter."

    # Call Device1.Pair directly so BlueZ uses the default agent (blueman-applet)
    # instead of an agent owned by a short-lived bluetoothctl process.
    path="$(busctl --system tree org.bluez --list 2>/dev/null | grep -i "/dev_${mac//:/_}\$" | head -n1)"
    if [ -n "$path" ]; then
        timeout 90 busctl --system call org.bluez "$path" org.bluez.Device1 Pair >/dev/null 2>&1
    else
        timeout 90 bluetoothctl pair "$mac" >/dev/null 2>&1
    fi

    if [ "$(bt_field "$mac" Paired)" = yes ]; then
        do_connect "$mac" "$name"
    else
        bluetoothctl remove "$mac" >/dev/null 2>&1
        bt_note "Pairing failed" "Put the device back into pairing mode, scan again and retry."
        bt_poke_bar
    fi
}

device_menu() {
    local mac="$1" name conn paired act
    local -a opts
    name="$(bt_field "$mac" Alias)"; [ -n "$name" ] || name="$mac"
    conn="$(bt_field "$mac" Connected)"
    paired="$(bt_field "$mac" Paired)"

    if [ "$conn" = yes ]; then
        opts=("Disconnect" "Forget this device" "Back")
    elif [ "$paired" = yes ]; then
        opts=("Connect" "Forget this device" "Back")
    else
        opts=("Pair and connect" "Back")
    fi

    act="$(printf '%s\n' "${opts[@]}" | pick "$name")" || return 0
    case "$act" in
        "Disconnect")          do_disconnect "$mac" "$name" ;;
        "Connect")             do_connect "$mac" "$name" ;;
        "Pair and connect")    do_pair "$mac" "$name" ;;
        "Forget this device")  do_forget "$mac" "$name" ;;
    esac
}

build_devices() {
    local conn paired all mac name pct n=0
    conn="$(bt_list Connected)"
    paired="$(bt_list Paired)"
    all="$(bt_list)"

    while IFS=$'\t' read -r mac name; do
        [ -n "$mac" ] || continue
        pct="$(bt_battery "$mac")"
        printf '●  %s   [connected%s]   (%s)\n' "$name" "${pct:+, ${pct}%}" "$mac"
        n=$((n + 1))
    done <<<"$conn"

    while IFS=$'\t' read -r mac name; do
        [ -n "$mac" ] || continue
        grep -qi "^$mac" <<<"$conn" && continue
        printf '○  %s   [paired]   (%s)\n' "$name" "$mac"
        n=$((n + 1))
    done <<<"$paired"

    while IFS=$'\t' read -r mac name; do
        [ -n "$mac" ] || continue
        grep -qi "^$mac" <<<"$paired" && continue
        # hide anonymous advertisers (name is just the address)
        [[ "$name" =~ ^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$ ]] && continue
        printf '+  %s   [new - select to pair]   (%s)\n' "$name" "$mac"
        n=$((n + 1))
    done <<<"$all"

    [ "$n" -gt 0 ] || printf '%s\n' "$L_NONE"
}

main_menu() {
    local choice mac
    while :; do
        if ! bt_have_controller; then
            rfkill unblock bluetooth 2>/dev/null; sleep 1
            if ! bt_have_controller; then
                bt_note "No Bluetooth adapter found" "Run cephalo-bt-doctor in a terminal to diagnose."
                exit 1
            fi
        fi

        if bt_powered; then
            choice="$({ printf '%s\n' "$L_OFF" "$L_SCAN"; build_devices; printf '%s\n' "$L_ADV"; } | pick "Bluetooth")" || exit 0
        else
            choice="$(printf '%s\n' "$L_ON" "$L_ADV" | pick "Bluetooth is off")" || exit 0
        fi

        case "$choice" in
            "$L_ON")   set_power on ;;
            "$L_OFF")  set_power off ;;
            "$L_SCAN") do_scan ;;
            "$L_NONE") ;;
            "$L_ADV")  setsid blueman-manager >/dev/null 2>&1 & exit 0 ;;
            *)
                mac="$(grep -oE '\(([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\)$' <<<"$choice" | tr -d '()')"
                [ -n "$mac" ] && device_menu "$mac"
                ;;
        esac
    done
}

main_menu
EOF

    # ---- diagnostics ------------------------------------------------------
    put 755 "$CHROOT/usr/local/bin/cephalo-bt-doctor" <<'EOF'
#!/usr/bin/env bash
# Quick Bluetooth/audio health report. Paste the output when asking for help.
echo "== Adapter / rfkill =="
rfkill list bluetooth 2>&1
bluetoothctl list 2>&1
bluetoothctl show 2>&1 | grep -E 'Controller|Name|Powered|Discoverable|Pairable|Discovering|Roles' 
echo
echo "== Services =="
printf 'bluetooth.service: %s\n' "$(systemctl is-active bluetooth)"
for u in pipewire wireplumber pipewire-pulse; do
    printf '%s (user): %s\n' "$u" "$(systemctl --user is-active "$u" 2>&1)"
done
printf 'blueman-applet: %s\n' "$(pgrep -f '[b]lueman-applet' >/dev/null && echo running || echo NOT running)"
echo
echo "== Kernel modules (m = module, B = built in, - = missing) =="
for m in bluetooth btusb btintel btrtl btbcm btmtk btqca hci_uart hidp rfcomm bnep uhid uinput; do
    if [ -d "/sys/module/$m" ] && [ ! -e "/sys/module/$m/initstate" ]; then s=B
    elif grep -q "^${m} " /proc/modules; then s=m
    elif [ -d "/sys/module/$m" ]; then s=B
    else s=-; fi
    printf '  %-10s %s\n' "$m" "$s"
done
echo
echo "== Recent kernel Bluetooth / firmware messages =="
journalctl -k -b --no-pager 2>/dev/null | grep -iE 'bluetooth|hci[0-9]|btusb|btintel|btrtl|btbcm|firmware.*(ibt|rtl_bt|BCM|mt7)' | tail -n 20
echo
echo "== Groups (needs 'bluetooth') =="
id
echo
echo "== Audio =="
wpctl status 2>&1 | head -n 25
EOF

    # Default Blueman look: no extra setup needed, but keep notifications on mako
    log "Bluetooth configuration written"
}

# Verify the bundled custom kernel was built with what Bluetooth needs.
BT_KERNEL_WARNING=""
check_kernel_bluetooth() {
    log "Checking the custom kernel for Bluetooth support"
    local cfg opt miss_req="" miss_rec="" report="$CHROOT/var/log/cephalo-bluetooth-kernel-check.txt"

    cfg="$(ls -1 "$CHROOT"/boot/config-* 2>/dev/null | sort -V | tail -n1 || true)"
    if [ -z "$cfg" ]; then
        BT_KERNEL_WARNING="No kernel config (/boot/config-*) found, so Bluetooth kernel support could not be verified. After first boot, run: cephalo-bt-doctor"
        echo "WARNING: $BT_KERNEL_WARNING" >&2
        return 0
    fi

    for opt in $BT_KERNEL_REQUIRED; do
        grep -Eq "^CONFIG_${opt}=(y|m)$" "$cfg" || miss_req="$miss_req CONFIG_$opt"
    done
    for opt in $BT_KERNEL_RECOMMENDED; do
        grep -Eq "^CONFIG_${opt}=(y|m)$" "$cfg" || miss_rec="$miss_rec CONFIG_$opt"
    done

    mkdir -p "$(dirname "$report")"
    {
        echo "Checked: $cfg"
        echo "Missing REQUIRED:   ${miss_req:- none}"
        echo "Missing recommended:${miss_rec:- none}"
    } > "$report"

    if [ -n "$miss_req" ]; then
        BT_KERNEL_WARNING="The custom kernel is missing options REQUIRED for Bluetooth:${miss_req}. Bluetooth will NOT work properly until the kernel is rebuilt with them."
        printf '\033[1;31mWARNING: %s\033[0m\n' "$BT_KERNEL_WARNING" >&2
    elif [ -n "$miss_rec" ]; then
        BT_KERNEL_WARNING="Kernel has the core Bluetooth options, but lacks some hardware-specific ones:${miss_rec}. Some adapters/devices may not work."
        printf '\033[1;33mNOTE: %s\033[0m\n' "$BT_KERNEL_WARNING" >&2
    else
        echo "Kernel Bluetooth options: all present."
    fi
}

install_main() {
    require_root
    if [ -d /sys/firmware/efi ]; then BOOT_MODE="uefi"; else BOOT_MODE="bios"; fi

    need_installer_tools
    [ -d "$PAYLOAD_DIR/kernel" ] || die "No bundled kernel at $PAYLOAD_DIR/kernel — run this from the Cephalo live ISO."

    ui_msg "Welcome to the Cephalo installer.\n\nThis will erase a disk of your choice and install Cephalo on it.\nThe system is downloaded and built from the Debian mirror, so a network connection is required and the install takes a while.\n\nDetected boot mode: $BOOT_MODE"

    ensure_network
    select_disk
    prompt_system_settings
    confirm_erase

    partition_disk
    mount_target_root
    debootstrap_base
    mount_target_esp
    write_fstab
    mount_chroot
    prepare_custom_kernel
    write_chroot_script
    run_chroot_setup
    configure_bluetooth
    check_kernel_bluetooth
    configure_target_users
    install_bootloader
    unmount_chroot
    cleanup

    log "Cephalo is installed on $INSTALL_DISK"
    if [ -n "$BT_KERNEL_WARNING" ] && [ "${INSTALL_YES:-0}" != "1" ]; then
        ui_msg "Bluetooth notice:\n\n$BT_KERNEL_WARNING"
    fi
    if [ "${INSTALL_YES:-0}" != "1" ] && \
       whiptail --title "$UI_TITLE" --yesno "Installation complete.\n\nRemove the install media, then reboot into your new system?" 11 64; then
        systemctl reboot
    fi
}

usage() {
    sed -n '2,/^set -euo/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-install}" in
    install)         install_main ;;
    -h|--help|help)  usage ;;
    *)               usage >&2; die "unknown argument: $1" ;;
esac
