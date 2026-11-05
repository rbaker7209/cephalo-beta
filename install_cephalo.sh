#!/usr/bin/env bash
#
# install-cephalo.sh — the Cephalo installer.
#
# Installs Cephalo (Debian Trixie + labwc, custom kernel, Firefox ESR, zRAM,
# full Bluetooth + PipeWire audio stack, and a minimal yambar status bar with a clock
# plus clickable Wi-Fi and Bluetooth managers)
# onto a disk. It is rolled into the minimal live ISO by build-cephalo-iso.sh under
# /opt/cephalo and launched with the `cephalo-install` command.
#
# It shows a disk selection menu, partitions the chosen disk (GPT, bootable
# on both BIOS and UEFI), debootstraps the system onto it, and installs GRUB.
# The kernel is downloaded from the Cephalo kernel repo on GitHub: a tuned
# microarchitecture build (e.g. amd-excavator) when one exists for the detected
# CPU, otherwise the generic x86-64-v1..v4 build matching the CPU's feature level.
# The copy bundled in the ISO is only the offline/failure fallback.
#
# Hardware is detected automatically (CPU, GPU, Wi-Fi, drive) and only the matching
# microcode, firmware and drivers are installed (NVIDIA driver picked with
# nvidia-detect, Broadcom wl for the cards that need it, SSD/NVMe/HDD tuning).
#
# Run as root inside the live session; a network connection is required.
#
# Usage:
#   cephalo-install           run the installer
#   cephalo-install detect    only show detected hardware + the kernel it would use
#
# Optional presets (skip the matching prompt): INSTALL_DISK, INSTALL_HOSTNAME,
# INSTALL_USER, INSTALL_PASS, INSTALL_YES=1 (skip the final erase confirmation).
# Overrides: KERNEL_MODE=auto|generic|bundled, KERNEL_VARIANT=v3|amd-excavator|...,
# INCLUDE_NVIDIA_DRIVER=auto|1|0, NVIDIA_DRIVER_PKG=<pkg>, INCLUDE_BROADCOM_STA=auto|1|0,
# INSTALL_ALL_FIRMWARE=1 (install every firmware package regardless of hardware).
#
# Boot splash: Plymouth is installed and configured (quiet splash on the kernel
# command line, early-KMS framebuffer in the initramfs) and the animated theme from
# SPLASH_URL is installed and set as the default. INSTALL_SPLASH=0 skips all of it;
# SPLASH_URL=<url> uses a different .tar.zst theme; SPLASH_THEME=<name> picks a
# specific theme if the archive holds more than one.
#
# Wallpaper: cephalo-wallpaper reads each monitor's resolution (wlr-randr) and shows the
# closest of the published sizes (<WALLPAPER_NAME>_<W>x<H>.png under WALLPAPER_BASE_URL),
# downloading only the sizes the attached monitors need once the machine is online, and
# follows monitor hot-plug. Nothing is downloaded at install time; until the first
# download finishes (e.g. no network on first boot) the plain gradient is shown.

set -euo pipefail

# ============================== CONFIG =====================================

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

DEBIAN_MIRROR="http://deb.debian.org/debian"
SUITE="trixie"

LOCALE="en_US.UTF-8"
KEYBOARD_LAYOUT="us"
TIMEZONE="${TIMEZONE:-UTC}"

# --- Assorted OS naming tags ----------------------------------------------
OS_VERSION="0.0.9.5"
OS_CODENAME="Tannuella"
OS_BRANCH="PRERELEASE"

# --- Hardware-compatibility toggles ---------------------------------------
# The installer detects the hardware (CPU, GPU, Wi-Fi, drive) and installs only
# what it needs. Each toggle below is  auto (detect)  |  1 (force on)  |  0 (never).
INCLUDE_BROADCOM_STA="${INCLUDE_BROADCOM_STA:-auto}"
INCLUDE_NVIDIA_DRIVER="${INCLUDE_NVIDIA_DRIVER:-auto}"
NVIDIA_DRIVER_PKG="${NVIDIA_DRIVER_PKG:-}"        # override nvidia-detect's choice
INSTALL_ALL_FIRMWARE="${INSTALL_ALL_FIRMWARE:-0}" # 1 = old behaviour, every firmware pkg

# --- Kernel: downloaded from the Cephalo kernel repo ----------------------
# Assets are named  <ver>-ceph-<rel>-x86-64-<variant>.tar.zst  where <variant> is
# either a generic level (v1..v4) or a microarchitecture (amd-excavator, ...).
KERNEL_REPO="${KERNEL_REPO:-rbaker7209/cephalo-kernel-beta}"
KERNEL_TAG="${KERNEL_TAG:-kernel_compile_full_0.0.8}"
KERNEL_PIN="${KERNEL_PIN:-6.8.1-ceph-0.0.8.6}"    # used only if the release's asset list can't be read
KERNEL_MODE="${KERNEL_MODE:-auto}"                # auto (microarch, then generic) | generic | bundled
KERNEL_VARIANT="${KERNEL_VARIANT:-}"              # force one variant, e.g. v3 or amd-excavator

# NOTE: these package sets describe the INSTALLED system (full labwc desktop).
# The live installer ISO is a separate, minimal command-line image defined in
# build-cephalo-iso.sh, so the two no longer need to be kept in sync.
# Package sets — added zstd and kmod for initramfs generation
BASE_PKGS="locales console-setup keyboard-configuration sudo systemd-sysv network-manager wpasupplicant firmware-linux-free initramfs-tools zstd kmod"

DISPLAY_PKGS="xserver-xorg xserver-xorg-legacy xserver-xorg-video-all xserver-xorg-input-all lightdm lightdm-gtk-greeter"
LABWC_PKGS="labwc xwayland thunar xfce4-power-manager"
LABWC_EXTRA_PKGS="yambar wofi foot mako-notifier swaybg swaylock mate-polkit papirus-icon-theme arc-theme fonts-noto fonts-noto-color-emoji fonts-font-awesome network-manager-gnome imagemagick wlr-randr wget ca-certificates"

EXTRA_PKGS="firefox-esr file-roller zram-tools micro"

# --- Bluetooth + audio stack ----------------------------------------------
# CORE packages must install (the build aborts otherwise) so we never ship a
# system with silently broken Bluetooth. EXTRA ones are nice-to-have.
BT_CORE_PKGS="bluez rfkill dbus-user-session libpam-systemd pipewire pipewire-alsa pipewire-pulse wireplumber libspa-0.2-bluetooth blueman"
BT_EXTRA_PKGS="bluez-obexd rtkit alsa-utils pulseaudio-utils pavucontrol libnotify-bin gir1.2-notify-0.7 playerctl"

# Kernel options the custom kernel needs for Bluetooth to work (checked, not enforced)
BT_KERNEL_REQUIRED="BT BT_BREDR BT_LE BT_RFCOMM BT_BNEP BT_HIDP BT_HCIBTUSB UHID INPUT_UINPUT RFKILL CRYPTO_USER_API_HASH CRYPTO_USER_API_SKCIPHER CRYPTO_CMAC CRYPTO_ECB CRYPTO_ECDH"
BT_KERNEL_RECOMMENDED="BT_INTEL BT_BCM BT_RTL BT_MTK BT_QCA BT_HCIBTUSB_BCM BT_HCIBTUSB_RTL BT_HCIBTUSB_MTK BT_HCIUART BT_HCIBTSDIO HIDRAW HID_GENERIC HID_BATTERY_STRENGTH"

# Firmware / driver packages are now chosen by detect_hardware(). These are the
# always-installed basics plus the "install everything" lists (INSTALL_ALL_FIRMWARE=1).
FIRMWARE_BASE_PKGS="firmware-misc-nonfree pciutils usbutils fwupd"
FIRMWARE_CORE_PKGS="firmware-misc-nonfree firmware-realtek firmware-atheros firmware-iwlwifi firmware-brcm80211 firmware-amd-graphics firmware-nvidia-graphics pciutils usbutils fwupd intel-microcode amd64-microcode"
FIRMWARE_EXTRA_PKGS="firmware-ath9k-htc firmware-libertas firmware-ralink firmware-mediatek firmware-sof-signed firmware-intel-sound firmware-intel-misc"
DKMS_PKGS="build-essential dkms"
BROADCOM_STA_PKGS="broadcom-sta-dkms"
MESA_PKGS="libgl1-mesa-dri libglx-mesa0 libegl-mesa0 mesa-vulkan-drivers mesa-va-drivers mesa-vdpau-drivers"

# Broadcom PCI device IDs (vendor 14e4) that need the proprietary "wl" driver, and
# those that have a mainline driver (brcmsmac) but fall back to wl if the kernel lacks it.
BCM_STA_IDS="4311 4312 4315 4328 4329 432b 432c 4331 43a0 43a1 43a2 43b1 4365"
BCM_SMAC_IDS="4353 4357 4358 4359 4727"

# --- Wallpaper ---------------------------------------------------------------
WALLPAPER_NAME="${WALLPAPER_NAME:-humble_lightripple}"
WALLPAPER_BASE_URL="${WALLPAPER_BASE_URL:-https://github.com/rbaker7209/cephalo-wallpapers/releases/download/humble_lightripple.v0.0.1}"

# --- Plymouth boot splash ---------------------------------------------------
INSTALL_SPLASH="${INSTALL_SPLASH:-1}"             # 1 = install Plymouth + the splash theme, 0 = skip
SPLASH_URL="${SPLASH_URL:-https://github.com/rbaker7209/cephalo-beta/releases/download/boot_splash.v0.0.2/spinning_cube.tar.zst}"
SPLASH_THEME="${SPLASH_THEME:-}"                  # optional: theme name inside the archive (auto-detected)
PLYMOUTH_PKGS="plymouth"                          # must install, otherwise the splash is skipped
PLYMOUTH_EXTRA_PKGS="plymouth-label plymouth-themes"              # nice-to-have (text label plugin)

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

# ============================ HARDWARE DETECTION ============================
# All of this runs on the live system *before* anything is erased.

HW_CPU_VENDOR=""; HW_CPU_NAME=""; HW_CPU_FLAGS=""; HW_CPU_UARCH=""
HW_X86_LEVEL=1; HW_IS_VM=0
HW_GPU_NVIDIA=0; HW_GPU_DESC=""
HW_WIFI_DESC=""; HW_WANT_BCM_STA=0; HW_REALTEK_DKMS=""
HW_WANT_NVIDIA=0
HW_DRIVE_TYPE="unknown"; HW_DRIVE_DESC=""
CPU_PKGS=""; GPU_PKGS=""; HW_FIRMWARE_PKGS=""; HW_FW_DIRS=""; DRIVE_PKGS=""
KERNEL_URL=""; KERNEL_VARIANT_USED=""

# add_word VAR w...   append words to a space-separated list (no duplicates)
add_word() { local -n _ref="$1"; local w; shift; for w in "$@"; do [[ " $_ref " == *" $w "* ]] || _ref="${_ref:+$_ref }$w"; done; }
# add_desc VAR text   append to a "; "-separated description
add_desc() { local -n _ref="$1"; _ref="${_ref:+$_ref; }$2"; }

# "class vendor device" (lowercase hex, no 0x) for every PCI device
pci_scan() {
    local d
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/class" ] || continue
        printf '%s %s %s\n' "$(<"$d/class")" "$(<"$d/vendor")" "$(<"$d/device")" | sed 's/0x//g'
    done
}

pci_name() {   # $1=vendor $2=device
    local n=""
    if command -v lspci >/dev/null 2>&1; then
        n="$(lspci -d "$1:$2" 2>/dev/null | head -n1 | sed 's/^[^ ]* [^:]*: //' || true)"
    fi
    echo "${n:-PCI $1:$2}"
}

cpu_has() {   # cpu_has flag...   (all must be present)
    local f
    for f in "$@"; do [[ " $HW_CPU_FLAGS " == *" $f "* ]] || return 1; done
    return 0
}

# x86-64 micro-architecture level (1-4) from the CPU flags
x86_level() {
    cpu_has cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 || { echo 1; return 0; }
    cpu_has avx avx2 bmi1 bmi2 f16c fma abm movbe xsave || { echo 2; return 0; }
    cpu_has avx512f avx512bw avx512cd avx512dq avx512vl || { echo 3; return 0; }
    echo 4
}

# AMD family/model (decimal, as in /proc/cpuinfo) -> variant name used in the repo
amd_uarch() {
    local fam="$1" mod="$2"
    case "$fam" in
        15)    if cpu_has pni; then echo k8-sse3; else echo ""; fi ;;   # plain K8: generic build
        16|18) echo amdfam10 ;;
        21)    if   [ "$mod" -ge 96 ]; then echo excavator
               elif [ "$mod" -ge 48 ]; then echo steamroller
               elif [ "$mod" -ge 16 ] || [ "$mod" -eq 2 ]; then echo piledriver
               else echo bulldozer; fi ;;
        23)    if [ "$mod" -ge 48 ]; then echo zen2; else echo zen1; fi ;;
        25)    if { [ "$mod" -ge 16 ] && [ "$mod" -le 31 ]; } || { [ "$mod" -ge 96 ] && [ "$mod" -le 127 ]; } || [ "$mod" -ge 160 ]
               then echo zen4; else echo zen3; fi ;;
        26)    echo zen5 ;;
        *)     echo "" ;;   # bobcat/jaguar etc. have no tuned build: generic
    esac
}

# Intel family 6 model/stepping (decimal) -> variant name used in the repo
intel_uarch() {
    case "$1" in
        28|38|39|53|54)            echo atom-bonnell ;;
        55|74|77|90|93)            echo atom-silvermont ;;
        92|95|122|134|150|156)     echo atom-goldmont ;;
        26|30|31|46)               echo nehalem ;;
        37|44|47)                  echo westmere ;;
        42|45)                     echo sandybridge ;;
        58|62)                     echo ivybridge ;;
        60|63|69|70)               echo haswell ;;
        61|71|79|86)               echo broadwell ;;
        78|94|142|158|165|166)     echo skylake ;;
        85)                        if [ "${2:-0}" -ge 5 ]; then echo cascadelake; else echo skylake-avx512; fi ;;
        106|108|125|126)           echo icelake ;;
        167)                       echo rocketlake ;;
        140|141)                   echo tigerlake ;;
        151|154)                   echo alderlake ;;
        183|186|191)               echo raptorlake ;;
        170|172|189|197|198)       echo meteorlake ;;
        143|207)                   echo sapphirerapids ;;
        *)                         echo "" ;;   # core2 etc.: generic
    esac
}

# Builds that can stand in for $1 (each is a subset of the CPU's features), best first.
uarch_chain() {
    case "$1" in
        zen5)            echo zen5 zen4 zen3 zen2 zen1 ;;
        zen4)            echo zen4 zen3 zen2 zen1 ;;
        zen3)            echo zen3 zen2 zen1 ;;
        zen2)            echo zen2 zen1 ;;
        excavator)       echo excavator steamroller piledriver bulldozer ;;
        steamroller)     echo steamroller piledriver bulldozer ;;
        piledriver)      echo piledriver bulldozer ;;
        meteorlake)      echo raptorlake alderlake ;;
        raptorlake)      echo raptorlake alderlake ;;
        sapphirerapids)  echo sapphirerapids icelake skylake-avx512 skylake ;;
        rocketlake)      echo icelake skylake-avx512 skylake ;;
        tigerlake)       echo tigerlake icelake skylake-avx512 skylake ;;
        icelake)         echo icelake skylake-avx512 skylake ;;
        cascadelake)     echo cascadelake skylake-avx512 skylake ;;
        skylake-avx512)  echo skylake-avx512 skylake ;;
        atom-goldmont)   echo atom-goldmont atom-silvermont ;;
        "")              ;;
        *)               echo "$1" ;;
    esac
}

detect_cpu() {
    local fam mod step
    HW_CPU_VENDOR="$(awk -F': *' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo || true)"
    HW_CPU_NAME="$(awk -F': *' '/^model name/ {print $2; exit}' /proc/cpuinfo || true)"
    HW_CPU_FLAGS="$(awk -F': *' '/^flags/ {print $2; exit}' /proc/cpuinfo || true)"
    fam="$(awk -F': *' '/^cpu family/ {print $2; exit}' /proc/cpuinfo || true)"
    step="$(awk -F': *' '/^stepping/ {print $2; exit}' /proc/cpuinfo || true)"
    mod="$(awk -F': *' '/^model[ \t]*:/ {print $2; exit}' /proc/cpuinfo || true)"
    [[ "$fam" =~ ^[0-9]+$ ]] || fam=0
    [[ "$mod" =~ ^[0-9]+$ ]] || mod=0
    [[ "$step" =~ ^[0-9]+$ ]] || step=0

    HW_X86_LEVEL="$(x86_level)"
    if cpu_has hypervisor; then HW_IS_VM=1; fi

    case "$HW_CPU_VENDOR" in
        GenuineIntel)
            add_word CPU_PKGS intel-microcode
            if [ "$fam" -eq 6 ]; then HW_CPU_UARCH="$(intel_uarch "$mod" "$step")"; fi ;;
        AuthenticAMD)
            add_word CPU_PKGS amd64-microcode
            HW_CPU_UARCH="$(amd_uarch "$fam" "$mod")" ;;
    esac

    # In a VM the virtual CPU may hide features the host really has, so a
    # microarch-tuned kernel is unsafe there; use the generic level instead.
    if [ "$HW_IS_VM" -eq 1 ]; then HW_CPU_UARCH=""; CPU_PKGS=""; fi
}

detect_gpu() {
    local cls ven dev nm
    while read -r cls ven dev; do
        case "$cls" in 03*) ;; *) continue ;; esac
        nm="$(pci_name "$ven" "$dev")"
        case "$ven" in
            10de) HW_GPU_NVIDIA=1
                  add_word GPU_PKGS firmware-nvidia-graphics
                  add_desc HW_GPU_DESC "NVIDIA: $nm" ;;
            1002) add_word GPU_PKGS firmware-amd-graphics xserver-xorg-video-amdgpu xserver-xorg-video-radeon
                  add_word HW_FW_DIRS amdgpu radeon
                  add_desc HW_GPU_DESC "AMD: $nm" ;;
            8086) add_word GPU_PKGS intel-media-va-driver i965-va-driver
                  add_desc HW_GPU_DESC "Intel: $nm" ;;
            1af4|1234|15ad|80ee|1b36)
                  add_desc HW_GPU_DESC "Virtual: $nm" ;;
            *)    add_desc HW_GPU_DESC "$nm" ;;
        esac
    done < <(pci_scan)
    add_word GPU_PKGS $MESA_PKGS
    [ -n "$HW_GPU_DESC" ] || HW_GPU_DESC="none detected (using generic drivers)"
}

# wifi_add BUS VENDOR DEVICE|PRODUCT   (PCI-style vendor ids)
wifi_add() {
    local bus="$1" ven="$2" dev="$3" label nm
    nm="$(pci_name "$ven" "$dev")"
    [ "$bus" = pci ] || nm="USB $ven:$dev"
    case "$ven" in
        14e4)
            add_word HW_FIRMWARE_PKGS firmware-brcm80211; add_word HW_FW_DIRS brcm
            if [[ " $BCM_STA_IDS " == *" $dev "* ]]; then
                HW_WANT_BCM_STA=1; label="needs proprietary wl driver"
            elif [[ " $BCM_SMAC_IDS " == *" $dev "* ]]; then
                [ "$HW_WANT_BCM_STA" = 1 ] || HW_WANT_BCM_STA=smac
                label="brcmsmac (wl fallback if the kernel lacks it)"
            else
                label="brcmfmac + firmware"
            fi
            add_desc HW_WIFI_DESC "Broadcom: $nm [$label]" ;;
        8086) add_word HW_FIRMWARE_PKGS firmware-iwlwifi; add_word HW_FW_DIRS iwlwifi
              add_desc HW_WIFI_DESC "Intel: $nm" ;;
        10ec) add_word HW_FIRMWARE_PKGS firmware-realtek
              [ "$dev" = c821 ] && add_word HW_REALTEK_DKMS rtl8821ce-dkms
              add_desc HW_WIFI_DESC "Realtek: $nm" ;;
        168c|17cb)
              add_word HW_FIRMWARE_PKGS firmware-atheros
              add_desc HW_WIFI_DESC "Atheros/Qualcomm: $nm" ;;
        14c3) add_word HW_FIRMWARE_PKGS firmware-mediatek
              add_desc HW_WIFI_DESC "MediaTek: $nm" ;;
        1814) add_word HW_FIRMWARE_PKGS firmware-ralink
              add_desc HW_WIFI_DESC "Ralink: $nm" ;;
        11ab) add_word HW_FIRMWARE_PKGS firmware-libertas firmware-misc-nonfree
              add_desc HW_WIFI_DESC "Marvell: $nm" ;;
        *)    add_desc HW_WIFI_DESC "$nm" ;;
    esac
    return 0
}

detect_wifi() {
    local cls ven dev n d uv up
    while read -r cls ven dev; do
        case "$cls" in 0280*) wifi_add pci "$ven" "$dev" ;; esac
    done < <(pci_scan)

    # USB adapters: only visible if the live system already created a wireless interface
    for n in /sys/class/net/*; do
        { [ -d "$n/wireless" ] || [ -d "$n/phy80211" ]; } || continue
        d="$(readlink -f "$n/device" 2>/dev/null || true)"
        case "$d" in */usb*) ;; *) continue ;; esac
        uv="$(cat "$d/../idVendor" 2>/dev/null || true)"; up="$(cat "$d/../idProduct" 2>/dev/null || true)"
        case "$uv" in
            0bda) wifi_add usb 10ec "$up" ;;
            0cf3) wifi_add usb 168c "$up" ;;
            148f) wifi_add usb 1814 "$up" ;;
            0e8d) wifi_add usb 14c3 "$up" ;;
            0a5c) wifi_add usb 14e4 "usb-$up" ;;
            8086) wifi_add usb 8086 "$up" ;;
        esac
    done
    [ -n "$HW_WIFI_DESC" ] || HW_WIFI_DESC="none detected"
}

detect_drive() {
    local d name rot model size
    d="$(readlink -f "$INSTALL_DISK")"; name="$(basename "$d")"
    rot="$(cat "/sys/block/$name/queue/rotational" 2>/dev/null || echo 1)"
    case "$name" in
        nvme*)       HW_DRIVE_TYPE=nvme ;;
        mmcblk*)     HW_DRIVE_TYPE=emmc ;;
        vd*|xvd*)    HW_DRIVE_TYPE=virtual ;;
        *)           if [ "$rot" = 0 ]; then HW_DRIVE_TYPE=ssd; else HW_DRIVE_TYPE=hdd; fi
                     [ "$HW_IS_VM" -eq 1 ] && HW_DRIVE_TYPE=virtual ;;
    esac
    case "$HW_DRIVE_TYPE" in
        nvme)    add_word DRIVE_PKGS nvme-cli smartmontools ;;
        ssd)     add_word DRIVE_PKGS smartmontools ;;
        hdd)     add_word DRIVE_PKGS hdparm smartmontools ;;
        emmc)    add_word DRIVE_PKGS mmc-utils ;;
    esac
    model="$(lsblk -dno MODEL "$d" 2>/dev/null | sed 's/ *$//' || true)"
    size="$(lsblk -dno SIZE "$d" 2>/dev/null | tr -d ' ' || true)"
    HW_DRIVE_DESC="$d  ${size:-?}  ${model:-unknown model}"
}

detect_hardware() {
    log "Detecting hardware"
    CPU_PKGS=""; GPU_PKGS=""; HW_FIRMWARE_PKGS=""; HW_FW_DIRS=""; DRIVE_PKGS=""
    HW_GPU_DESC=""; HW_WIFI_DESC=""; HW_WANT_BCM_STA=0; HW_REALTEK_DKMS=""; HW_GPU_NVIDIA=0
    detect_cpu
    detect_gpu
    detect_wifi
    detect_drive

    case "$INCLUDE_NVIDIA_DRIVER" in
        1) HW_WANT_NVIDIA=1 ;;
        0) HW_WANT_NVIDIA=0 ;;
        *) HW_WANT_NVIDIA="$HW_GPU_NVIDIA" ;;
    esac
    case "$INCLUDE_BROADCOM_STA" in
        1) HW_WANT_BCM_STA=1 ;;
        0) HW_WANT_BCM_STA=0 ;;
    esac
}

hw_summary() {
    local cpu_extra="x86-64-v$HW_X86_LEVEL" drv="" kern
    [ -n "$HW_CPU_UARCH" ] && cpu_extra="$HW_CPU_UARCH, $cpu_extra"
    [ "$HW_IS_VM" -eq 1 ] && cpu_extra="$cpu_extra, virtual machine"
    [ -n "$CPU_PKGS" ] && drv="microcode ($CPU_PKGS)"
    [ "$HW_WANT_NVIDIA" = 1 ] && drv="${drv:+$drv; }NVIDIA proprietary driver (picked by nvidia-detect)"
    [ "$HW_WANT_BCM_STA" != 0 ] && drv="${drv:+$drv; }Broadcom wl driver"
    [ -n "$HW_REALTEK_DKMS" ] && drv="${drv:+$drv; }$HW_REALTEK_DKMS"
    if [ -n "$KERNEL_URL" ]; then kern="${KERNEL_URL##*/}"; else kern="ISO-bundled kernel"; fi
    cat <<SUMMARY
CPU:      ${HW_CPU_NAME:-unknown}
          $cpu_extra
GPU:      $HW_GPU_DESC
Wi-Fi:    $HW_WIFI_DESC
Drive:    $HW_DRIVE_DESC  [$HW_DRIVE_TYPE]
Extras:   ${drv:-nothing special needed}
Kernel:   $kern
SUMMARY
}

show_hw_summary() {
    [ "${INSTALL_YES:-0}" = "1" ] && { hw_summary; return 0; }
    whiptail --title "$UI_TITLE" --msgbox "Detected hardware and what will be installed:\n\n$(hw_summary)" 20 78
}

write_hw_report() {
    mkdir -p "$CHROOT/var/log"
    { echo "Cephalo hardware report ($(date -u +%FT%TZ))"; echo; hw_summary; echo; } > "$CHROOT/var/log/cephalo-hardware.txt"
}

# ============================ KERNEL FROM THE REPO ============================

# Candidate variants, best first: tuned microarch builds, then generic x86-64-v<N>.
kernel_variant_candidates() {
    local p="" n u
    if [ -n "$KERNEL_VARIANT" ]; then echo "$KERNEL_VARIANT"; return 0; fi
    if [ "$KERNEL_MODE" != "generic" ] && [ -n "$HW_CPU_UARCH" ]; then
        case "$HW_CPU_VENDOR" in AuthenticAMD) p=amd ;; GenuineIntel) p=intel ;; esac
        for u in $(uarch_chain "$HW_CPU_UARCH"); do
            echo "$p-$u"
        done
    fi
    for ((n = HW_X86_LEVEL; n >= 1; n--)); do echo "v$n"; done
}

resolve_kernel() {
    KERNEL_URL=""; KERNEL_VARIANT_USED=""
    if [ "$KERNEL_MODE" = "bundled" ]; then
        log "Kernel: using the ISO-bundled kernel (KERNEL_MODE=bundled)"
        return 0
    fi
    log "Looking for the best kernel in $KERNEL_REPO"
    local api base assets cand best
    api="https://api.github.com/repos/$KERNEL_REPO/releases/tags/$KERNEL_TAG"
    base="https://github.com/$KERNEL_REPO/releases/download/$KERNEL_TAG"
    assets="$(wget -qO- --timeout=15 --tries=2 "$api" 2>/dev/null \
                | grep -oE '"name": *"[^"]+\.tar\.zst"' | sed -E 's/.*"([^"]+)"$/\1/' || true)"

    for cand in $(kernel_variant_candidates); do
        best=""
        if [ -n "$assets" ]; then
            best="$(printf '%s\n' "$assets" | grep -F -- "-x86-64-${cand}.tar.zst" | sort -V | tail -n1 || true)"
        elif [ -n "$KERNEL_PIN" ]; then
            best="${KERNEL_PIN}-x86-64-${cand}.tar.zst"
            wget -q --spider --timeout=15 --tries=2 "$base/$best" 2>/dev/null || best=""
        fi
        if [ -n "$best" ]; then
            KERNEL_URL="$base/$best"; KERNEL_VARIANT_USED="$cand"
            echo "Selected kernel: $best"
            return 0
        fi
    done
    echo "WARNING: no matching kernel found in the repo (or it is unreachable)." >&2
}

# Called with the target mounted: download the chosen kernel, stage the ISO copy as a fallback.
prepare_custom_kernel() {
    mkdir -p "$CHROOT/tmp"
    if [ -n "$KERNEL_URL" ]; then
        log "Downloading kernel ${KERNEL_URL##*/}"
        if ! wget -q --show-progress --timeout=30 --tries=3 -O "$CHROOT/tmp/cephalo-kernel.tar.zst" "$KERNEL_URL"; then
            echo "WARNING: kernel download failed; using the ISO-bundled kernel." >&2
            rm -f "$CHROOT/tmp/cephalo-kernel.tar.zst"; KERNEL_URL=""; KERNEL_VARIANT_USED=""
        fi
    fi
    if [ -d "$PAYLOAD_DIR/kernel" ]; then
        mkdir -p "$CHROOT/tmp/custom_kernel_bundled"
        cp -a "$PAYLOAD_DIR/kernel"/. "$CHROOT/tmp/custom_kernel_bundled/"
    fi
    [ -f "$CHROOT/tmp/cephalo-kernel.tar.zst" ] || [ -d "$CHROOT/tmp/custom_kernel_bundled" ] \
        || die "No kernel available (download failed and nothing is bundled at $PAYLOAD_DIR/kernel)."
}

# Called with the target mounted: fetch the Plymouth theme archive (non-fatal).
prepare_splash() {
    [ "$INSTALL_SPLASH" = "1" ] || return 0
    mkdir -p "$CHROOT/tmp"
    log "Downloading boot splash theme ${SPLASH_URL##*/}"
    if ! wget -q --show-progress --timeout=30 --tries=3 -O "$CHROOT/tmp/cephalo-splash.tar.zst" "$SPLASH_URL"; then
        echo "WARNING: boot splash download failed; Plymouth will use its stock theme." >&2
        rm -f "$CHROOT/tmp/cephalo-splash.tar.zst"
    fi
}

# Kernel options Plymouth needs. Warn-only: the install still completes.
check_kernel_splash() {
    [ "$INSTALL_SPLASH" = "1" ] || return 0
    local cfg opt miss=""
    cfg="$(ls -1 "$CHROOT"/boot/config-* 2>/dev/null | sort -V | tail -n1 || true)"
    [ -n "$cfg" ] || { echo "NOTE: no kernel config found; could not verify Plymouth kernel support." >&2; return 0; }
    for opt in VT DEVTMPFS TMPFS UNIX; do
        grep -Eq "^CONFIG_${opt}=(y|m)$" "$cfg" || miss="$miss CONFIG_$opt"
    done
    if ! grep -Eq '^CONFIG_DRM=(y|m)$' "$cfg" && ! grep -Eq '^CONFIG_FB=(y|m)$' "$cfg"; then
        miss="$miss CONFIG_DRM(or CONFIG_FB)"
    fi
    grep -Eq '^CONFIG_DRM_FBDEV_EMULATION=(y|m)$|^CONFIG_FRAMEBUFFER_CONSOLE=(y|m)$' "$cfg" \
        || miss="$miss CONFIG_DRM_FBDEV_EMULATION/CONFIG_FRAMEBUFFER_CONSOLE"
    if [ -n "$miss" ]; then
        printf '\033[1;33mNOTE: the kernel lacks options Plymouth relies on:%s. The boot splash may not display.\033[0m\n' "$miss" >&2
    else
        echo "Kernel Plymouth options: all present."
    fi
}

configure_grub_splash() {
    [ "$INSTALL_SPLASH" = "1" ] || return 0

    if ! chroot "$CHROOT" dpkg -s plymouth >/dev/null 2>&1; then
        echo "WARNING: Plymouth is not installed in the target; leaving the kernel command line alone." >&2
        return 0
    fi

    log "Configuring GRUB for the boot splash"

    local f="$CHROOT/etc/default/grub" cur
    [ -f "$f" ] || : > "$f"

    cur="$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"[[:space:]]*$/\1/p' "$f" | tail -n1)"

    for w in quiet splash vt.global_cursor_default=0; do
        [[ " $cur " == *" $w "* ]] || cur="${cur:+$cur }$w"
    done

    sed -i \
        '/^GRUB_CMDLINE_LINUX_DEFAULT=/d;
         /^GRUB_GFXPAYLOAD_LINUX=/d;
         /^GRUB_GFXMODE=/d;
         /^GRUB_TIMEOUT_STYLE=/d;
         /^GRUB_TIMEOUT=/d' "$f"

    {
        printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$cur"
        echo 'GRUB_GFXMODE=auto'
        echo 'GRUB_GFXPAYLOAD_LINUX=keep'

        # Hide the GRUB menu for seamless boot
        echo 'GRUB_TIMEOUT_STYLE=hidden'
        echo 'GRUB_TIMEOUT=0'
    } >> "$f"
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

# --- helpers -----------------------------------------------------------------
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
hwnote() { echo "\$*" | tee -a /var/log/cephalo-hardware.txt >&2; }
try_install() {
    local p failed=""
    for p in "\$@"; do
        apt-get install -y "\$p" || failed="\$failed \$p"
    done
    if [ -n "\$failed" ]; then hwnote "WARNING: failed to install:\$failed (continuing without them)"; fi
    return 0
}
# DKMS packages: if one fails to build, purge it again so apt/dpkg stay healthy.
dkms_install() {
    local p
    for p in "\$@"; do
        if ! apt-get install -y "\$p"; then
            hwnote "WARNING: \$p failed to install/build for kernel \$CKVER; removing it"
            apt-get purge -y "\$p" || true
            apt-get autoremove -y --purge || true
            dpkg --configure -a || true
        fi
    done
}

# --- Custom kernel (downloaded tarball preferred, ISO-bundled copy as fallback) ---
flatten_kernel_dir() {
    local d="\$1" only
    while [ "\$(find "\$d" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]; do
        only="\$(find "\$d" -mindepth 1 -maxdepth 1)"
        [ -d "\$only" ] || break
        case "\$(basename "\$only")" in boot|lib|lib64|usr|etc) break ;; esac
        d="\$only"
    done
    echo "\$d"
}
reset_kernel_files() {
    rm -f /boot/vmlinuz-* /boot/initrd.img-* /boot/System.map-* /boot/config-*
    rm -rf /lib/modules/*
}
kernel_ok() { ls /boot/vmlinuz-* >/dev/null 2>&1 && [ -n "\$(ls -A /lib/modules 2>/dev/null)" ]; }
install_kernel_from() {
    local d m
    d="\$(flatten_kernel_dir "\$1")"
    if ls "\$d"/*.deb >/dev/null 2>&1; then
        apt-get install -y "\$d"/*.deb || return 1
        return 0
    fi
    # rootfs-style tarball (boot/, lib/modules/, usr/src/) or a flat directory
    if [ -d "\$d/boot" ]; then cp -a "\$d/boot/." /boot/; fi
    cp -f "\$d"/vmlinuz-* "\$d"/initrd.img-* "\$d"/System.map-* "\$d"/config-* /boot/ 2>/dev/null || true
    mkdir -p /lib/modules
    for m in "\$d/lib/modules" "\$d/usr/lib/modules"; do
        if [ -d "\$m" ]; then cp -a "\$m"/. /lib/modules/; fi
    done
    if [ -d "\$d/usr/src" ]; then mkdir -p /usr/src; cp -a "\$d/usr/src"/. /usr/src/; fi
    return 0
}

KERNEL_DONE=0
if [ -f /tmp/cephalo-kernel.tar.zst ]; then
    echo "Installing downloaded kernel ($KERNEL_VARIANT_USED)..."
    rm -rf /tmp/kernel_dl; mkdir -p /tmp/kernel_dl
    if tar --zstd -xf /tmp/cephalo-kernel.tar.zst -C /tmp/kernel_dl && install_kernel_from /tmp/kernel_dl && kernel_ok; then
        KERNEL_DONE=1
    else
        echo "WARNING: downloaded kernel could not be installed; falling back to the ISO-bundled kernel" >&2
        reset_kernel_files
    fi
    rm -rf /tmp/kernel_dl /tmp/cephalo-kernel.tar.zst
fi
if [ "\$KERNEL_DONE" -eq 0 ] && [ -d /tmp/custom_kernel_bundled ]; then
    echo "Installing ISO-bundled kernel..."
    if install_kernel_from /tmp/custom_kernel_bundled && kernel_ok; then KERNEL_DONE=1; fi
fi
rm -rf /tmp/custom_kernel_bundled
if [ "\$KERNEL_DONE" -ne 1 ]; then echo "ERROR: no kernel could be installed" >&2; exit 1; fi

CKVER="\$(ls /lib/modules | sort -V | tail -n1)"
echo "\$CKVER" > /root/.cephalo-kver
HAVE_HEADERS=0
[ -e "/lib/modules/\$CKVER/build/Makefile" ] && HAVE_HEADERS=1
hwnote "Kernel: \$CKVER  (variant: ${KERNEL_VARIANT_USED:-ISO-bundled}, headers present: \$HAVE_HEADERS)"

# --- Hardware-specific packages (chosen by the installer's detection) ----------
# CPU microcode: only the vendor that matches (none inside a VM)
try_install $CPU_PKGS

# Firmware: base set + whatever the detected Wi-Fi / GPU needs
if [ "$INSTALL_ALL_FIRMWARE" = "1" ]; then
    try_install $FIRMWARE_CORE_PKGS $FIRMWARE_EXTRA_PKGS
else
    try_install $FIRMWARE_BASE_PKGS $HW_FIRMWARE_PKGS
fi

for fwdir in $HW_FW_DIRS ; do
    if [ -d "/lib/firmware/\$fwdir" ] && [ -n "\$(ls -A "/lib/firmware/\$fwdir" 2>/dev/null)" ]; then
        FWCOUNT=\$(ls -1 "/lib/firmware/\$fwdir" | wc -l)
        echo "firmware check: /lib/firmware/\$fwdir populated (\$FWCOUNT files)"
    else
        hwnote "WARNING: /lib/firmware/\$fwdir is missing or empty — matching hardware will fail to init"
    fi
done

# GPU userspace (Mesa, VA-API, vendor X drivers) and drive tools
try_install $GPU_PKGS
try_install $DRIVE_PKGS

# --- Out-of-tree drivers (DKMS): Broadcom wl, NVIDIA, Realtek ------------------
BCM_STA="$HW_WANT_BCM_STA"
if [ "\$BCM_STA" = "smac" ]; then
    if grep -qsE '^CONFIG_BRCMSMAC=(y|m)\$' "/boot/config-\$CKVER"; then
        BCM_STA=0
    else
        BCM_STA=1
        hwnote "Kernel has no brcmsmac driver: using the Broadcom STA (wl) driver instead"
    fi
fi
RT_DKMS="$HW_REALTEK_DKMS"
if [ -n "\$RT_DKMS" ] && grep -qsE '^CONFIG_RTW88_8821CE=(y|m)\$' "/boot/config-\$CKVER"; then RT_DKMS=""; fi

if [ "\$BCM_STA" = "1" ] || [ "$HW_WANT_NVIDIA" = "1" ] || [ -n "\$RT_DKMS" ]; then
    if [ "\$HAVE_HEADERS" != "1" ]; then
        hwnote "WARNING: this kernel ships no headers (/lib/modules/\$CKVER/build), so DKMS drivers (Broadcom wl / NVIDIA / Realtek) cannot be built. Falling back to in-kernel drivers (nouveau etc.). Add headers to the kernel tarball to enable them."
    else
        apt-get install -y $DKMS_PKGS

        # The chroot would otherwise report the *live ISO's* kernel to DKMS. Make
        # 'uname -r' return the installed custom kernel while the drivers build.
        cat > /usr/local/bin/uname <<'EOS'
#!/bin/sh
if [ "\$1" = "-r" ] && [ -s /root/.cephalo-kver ]; then cat /root/.cephalo-kver; else exec /usr/bin/uname "\$@"; fi
EOS
        chmod +x /usr/local/bin/uname

        if [ "\$BCM_STA" = "1" ]; then
            hwnote "Broadcom Wi-Fi that needs the proprietary driver: installing $BROADCOM_STA_PKGS"
            dkms_install $BROADCOM_STA_PKGS
        fi

        if [ -n "\$RT_DKMS" ]; then
            hwnote "Realtek 8821CE Wi-Fi and the kernel has no rtw88 driver for it: installing \$RT_DKMS"
            dkms_install \$RT_DKMS
        fi

        if [ "$HW_WANT_NVIDIA" = "1" ]; then
            apt-get install -y nvidia-detect || true
            NV_PKG="$NVIDIA_DRIVER_PKG"
            if [ -z "\$NV_PKG" ]; then
                NV_PKG="\$(nvidia-detect 2>/dev/null | awk '/recommended to install the/ {getline; print \$1; exit}' || true)"
            fi
            case "\$NV_PKG" in nvidia-*driver) ;; *) NV_PKG="" ;; esac
            if [ -n "\$NV_PKG" ]; then
                hwnote "NVIDIA: nvidia-detect selected \$NV_PKG"
                dkms_install "\$NV_PKG"
                if dpkg -s "\$NV_PKG" >/dev/null 2>&1; then
                    echo "options nvidia-drm modeset=1" > /etc/modprobe.d/cephalo-nvidia-drm.conf
                    try_install libnvidia-egl-wayland1
                fi
            else
                hwnote "NVIDIA: no proprietary driver supports this GPU (or nvidia-detect found none); using nouveau"
            fi
        fi

        # Make sure every DKMS module is built for the installed kernel
        dkms autoinstall -k "\$CKVER" || true
        dkms status || true
        rm -f /usr/local/bin/uname
    fi
fi
rm -f /root/.cephalo-kver

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

cat > /etc/os-release <<'EOF'
PRETTY_NAME="Cephalo OS ${OS_BRANCH} ${OS_CODENAME}"
NAME="cephalo ${OS_VERSION}"
VERSION_ID="${OS_VERSION}"
VERSION="${OS_VERSION} (${OS_CODENAME})"
VERSION_CODENAME="${OS_CODENAME}"
DEBIAN_VERSION_FULL=13.7
ID=cephalo
HOME_URL="https://github.com/rbaker7209/cephalo-beta"
SUPPORT_URL="https://github.com/rbaker7209/cephalo-beta/issues/"
BUG_REPORT_URL="https://github.com/rbaker7209/cephalo-beta/issues/"
EOF

# --- labwc desktop configuration ---
mkdir -p /usr/share/backgrounds
if command -v convert >/dev/null 2>&1; then
    convert -size 1920x1080 gradient:'#1e1e2e-#313244' /usr/share/backgrounds/cephalo-gradient.png || true
fi

mkdir -p /etc/skel/.config/labwc /etc/skel/.config/yambar /etc/skel/.config/mako \
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

if command -v cephalo-wallpaper >/dev/null 2>&1; then
    # per-monitor wallpaper sized to each screen; keeps running to follow hot-plug
    cephalo-wallpaper &
elif [ -f /usr/share/backgrounds/cephalo-gradient.png ] && command -v swaybg >/dev/null 2>&1; then
    swaybg -i /usr/share/backgrounds/cephalo-gradient.png -m fill &
elif command -v swaybg >/dev/null 2>&1; then
    swaybg -c 1e1e2e &
fi

command -v yambar >/dev/null 2>&1 && yambar &
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

# (no nm-applet: yambar has no tray. Wi-Fi is handled by cephalo-wifi-menu instead.)
# Blueman applet = Bluetooth pairing agent (PIN / passkey prompts) + notifications.
# It is started for the agent only; there is no tray icon to show.
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
    <keybind key="W-w"><action name="Execute" command="cephalo-wifi-menu"/></keybind>
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

cat > /etc/skel/.config/yambar/config.yml <<'EOF'
# Cephalo status bar (yambar): clock, Wi-Fi and Bluetooth. Colours are RRGGBBAA.
#   Wi-Fi:      left-click = network menu (Super+W)   right-click = connection editor
#   Bluetooth:  left-click = device menu  (Super+B)   right-click = Blueman
# yambar does not run click handlers through a shell, so use absolute paths.

wifi-click: &wifi-click
  left: /usr/local/bin/cephalo-wifi-menu
  right: /usr/bin/nm-connection-editor

bt-click: &bt-click
  left: /usr/local/bin/cephalo-bt-menu
  right: /usr/bin/blueman-manager

bar:
  location: top
  layer: top
  height: 32
  background: 1e1e2ee6
  foreground: cdd6f4ff
  font: "Noto Sans:pixelsize=13, FontAwesome:pixelsize=13"
  left-margin: 10
  right-margin: 10
  spacing: 10

  center:
    - clock:
        date-format: "%a %d %b"
        time-format: "%H:%M"
        content:
          - string:
              text: "{date}  {time}"

  right:
    # Wi-Fi: cephalo-wifi-status prints  state (wifi|ethernet|connecting|
    # disconnected|off|missing)  and  label.
    - script:
        path: /usr/local/bin/cephalo-wifi-status
        content:
          map:
            conditions:
              state == wifi:
                string:
                  text: "\uf1eb  {label}"
                  foreground: 89b4faff
                  on-click: *wifi-click
              state == ethernet:
                string:
                  text: "\uf1eb  {label}"
                  on-click: *wifi-click
              state == connecting:
                string:
                  text: "\uf1eb  {label}"
                  foreground: f9e2afff
                  on-click: *wifi-click
            default:
              string:
                text: "\uf1eb  {label}"
                foreground: 6c7086ff
                on-click: *wifi-click

    # Bluetooth: cephalo-bt-status prints  state (connected|on|off|missing),
    # label (battery % of connected devices) and the bools  low  /  critical.
    - script:
        path: /usr/local/bin/cephalo-bt-status
        content:
          map:
            conditions:
              critical:
                string:
                  text: "\uf293  {label}"
                  foreground: f38ba8ff
                  on-click: *bt-click
              low:
                string:
                  text: "\uf293  {label}"
                  foreground: f9e2afff
                  on-click: *bt-click
              state == connected:
                string:
                  text: "\uf293  {label}"
                  foreground: 89b4faff
                  on-click: *bt-click
              state == on:
                string:
                  text: "\uf293  {label}"
                  on-click: *bt-click
            default:
              string:
                text: "\uf293  {label}"
                foreground: 6c7086ff
                on-click: *bt-click
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
# --- Plymouth boot splash ----------------------------------------------------
# Installed after the kernel and every other package so the single initramfs
# rebuild just below picks up the theme for every installed kernel.
if [ "$INSTALL_SPLASH" = "1" ]; then
    if apt-get install -y $PLYMOUTH_PKGS; then
        try_install $PLYMOUTH_EXTRA_PKGS

        SPLASH_NAME="$SPLASH_THEME"
        if [ -f /tmp/cephalo-splash.tar.zst ]; then
            rm -rf /tmp/splash_dl; mkdir -p /tmp/splash_dl
            if tar --zstd -xf /tmp/cephalo-splash.tar.zst -C /tmp/splash_dl; then
                if [ -n "\$SPLASH_NAME" ]; then
                    PFILE="\$(find /tmp/splash_dl -type f -name "\$SPLASH_NAME.plymouth" | head -n1)"
                else
                    PFILE="\$(find /tmp/splash_dl -type f -name '*.plymouth' | sort | head -n1)"
                fi
                if [ -n "\$PFILE" ]; then
                    SPLASH_NAME="\$(basename "\$PFILE" .plymouth)"
                    SPLASH_DEST="/usr/share/plymouth/themes/\$SPLASH_NAME"
                    rm -rf "\$SPLASH_DEST"; mkdir -p "\$SPLASH_DEST"
                    cp -a "\$(dirname "\$PFILE")"/. "\$SPLASH_DEST"/
                    # make sure the theme's own paths point at where it now lives
                    sed -i -E "/^(ImageDir|ScriptFile)=/ s#/usr/share/plymouth/themes/[^/]+#/usr/share/plymouth/themes/\$SPLASH_NAME#" "\$SPLASH_DEST/\$SPLASH_NAME.plymouth"
                    chown -R root:root "\$SPLASH_DEST"
                    find "\$SPLASH_DEST" -type d -exec chmod 755 {} +
                    find "\$SPLASH_DEST" -type f -exec chmod 644 {} +
                    hwnote "Boot splash theme installed: \$SPLASH_NAME"
                    hwnote "--- \$SPLASH_NAME.plymouth ---"
                    hwnote "\$(cat "\$SPLASH_DEST/\$SPLASH_NAME.plymouth")"
                    hwnote "--- theme files: \$(ls "\$SPLASH_DEST" | wc -l) ---"
                    SPLASH_MOD="\$(sed -n 's/^ModuleName=[[:space:]]*//p' "\$SPLASH_DEST/\$SPLASH_NAME.plymouth" | head -n1)"
                    if [ -n "\$SPLASH_MOD" ] && ! ls /usr/lib/*/plymouth/"\$SPLASH_MOD".so /usr/lib/plymouth/"\$SPLASH_MOD".so >/dev/null 2>&1; then
                        hwnote "WARNING: Plymouth plugin '\$SPLASH_MOD' (needed by the theme) is not installed"
                    fi
                else
                    SPLASH_NAME=""
                    hwnote "WARNING: the splash archive holds no .plymouth theme file; using Plymouth's stock theme"
                fi
            else
                SPLASH_NAME=""
                hwnote "WARNING: could not extract the splash archive; using Plymouth's stock theme"
            fi
            rm -rf /tmp/splash_dl /tmp/cephalo-splash.tar.zst
        else
            SPLASH_NAME=""
        fi

        # Make the splash theme the default (no -R: that would rebuild the initramfs
        # for the live ISO's kernel, not ours; the loop below does the right rebuild).
        # (capture the list first: 'plymouth-set-default-theme -l | grep -q' can die of SIGPIPE under pipefail)
        THEME_LIST="\$(plymouth-set-default-theme --list 2>/dev/null || true)"
        if [ -n "\$SPLASH_NAME" ] && printf '%s\\n' "\$THEME_LIST" | grep -qx "\$SPLASH_NAME"; then
            plymouth-set-default-theme "\$SPLASH_NAME"
            mkdir -p /etc/plymouth
            cat > /etc/plymouth/plymouthd.conf <<EOP
[Daemon]
Theme=\$SPLASH_NAME
ShowDelay=0
DeviceTimeout=8
EOP
            hwnote "Plymouth default theme: \$SPLASH_NAME"
        elif [ -n "\$SPLASH_NAME" ]; then
            hwnote "WARNING: Plymouth does not list theme \$SPLASH_NAME; leaving the stock theme"
        fi

        # Bring up the framebuffer / KMS as early as possible so the splash shows from the start
        mkdir -p /etc/initramfs-tools/conf.d
        echo "FRAMEBUFFER=y" > /etc/initramfs-tools/conf.d/cephalo-splash
    else
        hwnote "WARNING: Plymouth could not be installed; the system will boot without a splash"
    fi
fi

# --- Force Initramfs Creation for Custom Kernels ---
if [ -d /lib/modules ]; then
    for kvers in \$(ls /lib/modules); do
        echo "Generating initramfs for kernel version: \$kvers"
        depmod -a "\$kvers" || true
        update-initramfs -c -k "\$kvers" || update-initramfs -u -k "\$kvers" || true
    done
fi

# Verify the splash theme really is inside each initramfs
if [ -n "\${SPLASH_NAME:-}" ]; then
    for initrd in /boot/initrd.img-*; do
        [ -e "\$initrd" ] || continue
        if lsinitramfs "\$initrd" 2>/dev/null | grep -q "plymouth/themes/\$SPLASH_NAME/"; then
            hwnote "initramfs OK (contains theme \$SPLASH_NAME): \$initrd"
        else
            hwnote "WARNING: theme \$SPLASH_NAME is NOT in \$initrd -- the splash will not show for that kernel"
        fi
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

Boot mode:  $BOOT_MODE    Drive: $HW_DRIVE_TYPE    Kernel: ${KERNEL_VARIANT_USED:-ISO-bundled}
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

    configure_grub_splash
    chroot "$CHROOT" update-grub

    ls "$CHROOT"/boot/vmlinuz-* >/dev/null 2>&1 || die "No kernel found in the installed system's /boot"
    grep -q '^menuentry' "$CHROOT/boot/grub/grub.cfg" || die "grub.cfg has no boot entries"
}


# Drive tuning for the detected type (SSD / NVMe / HDD / eMMC / virtual)
configure_drive() {
    log "Tuning for a $HW_DRIVE_TYPE drive"
    # I/O scheduler picks itself per device at boot from the rotational flag, so
    # the rules stay correct even if the disk is later moved to another machine.
    put 644 "$CHROOT/etc/udev/rules.d/60-cephalo-ioscheduler.rules" <<'EOF2'
# NVMe: the device does its own queueing
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
# SATA/USB SSD and eMMC
ACTION=="add|change", KERNEL=="sd[a-z]|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# Spinning disks: BFQ (if the kernel has it) plus a bigger readahead
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq", ATTR{queue/read_ahead_kb}="1024"
EOF2
    case "$HW_DRIVE_TYPE" in
        nvme|ssd|emmc|virtual)
            # weekly TRIM instead of the 'discard' mount option
            chroot "$CHROOT" systemctl enable fstrim.timer \
                || echo "WARNING: could not enable fstrim.timer" >&2 ;;
        hdd)
            # no TRIM on spinning disks; smartd (from smartmontools) watches the disk health
            chroot "$CHROOT" systemctl enable smartmontools.service >/dev/null 2>&1 || true ;;
    esac
}

# ---------------------------------------------------------------------------
# Bluetooth: configuration, helper scripts, yambar integration, kernel check
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

# Wake cephalo-bt-status (the yambar script module) so the bar refreshes immediately.
bt_poke_bar() { pkill -USR1 -f /usr/local/bin/cephalo-bt-status 2>/dev/null; return 0; }
EOF

    # ---- yambar module: status + per-device battery -----------------------
    put 755 "$CHROOT/usr/local/bin/cephalo-bt-status" <<'EOF'
#!/usr/bin/env bash
# yambar "script" module, continuous mode. Prints a tag set whenever something
# changes:  state (connected|on|off|missing)  label  low  critical
# cephalo-bt-menu sends SIGUSR1 to refresh immediately.
. /usr/local/lib/cephalo/bt-lib.sh

INTERVAL=10
YPID=$PPID
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/cephalo-bt"
mkdir -p "$STATE_DIR" 2>/dev/null

trap 'exit 0' TERM INT HUP
trap ':' USR1                      # just wakes the sleep below

last=""
# emit STATE LABEL LOW CRITICAL   (only prints when something changed)
emit() {
    local out nl=$'\n' lbl="${2//[|$'\n']/ }"
    out="state|string|$1${nl}label|string|${lbl}${nl}low|bool|$3${nl}critical|bool|$4"
    [ "$out" = "$last" ] && return 0
    last="$out"
    printf '%s\n\n' "$out"
}

collect() {
    local mac name pct flag count=0 lowest=101 joined="" label low=false crit=false

    if ! bt_have_controller; then emit missing "n/a" false false; return; fi
    if ! bt_powered;         then emit off "off" false false;     return; fi

    while IFS=$'\t' read -r mac name; do
        [ -n "$mac" ] || continue
        count=$((count + 1))
        pct="$(bt_battery "$mac")"
        flag="$STATE_DIR/low-${mac//:/_}"
        if [[ "$pct" =~ ^[0-9]+$ ]]; then
            joined+="${joined:+ · }${pct}%"
            [ "$pct" -lt "$lowest" ] && lowest="$pct"
            # one low-battery notification per discharge cycle
            if [ "$pct" -le 15 ] && [ ! -e "$flag" ]; then
                touch "$flag"
                command -v notify-send >/dev/null 2>&1 &&
                    notify-send -a Bluetooth -u critical "Low battery" "$name is at ${pct}%"
            elif [ "$pct" -ge 25 ]; then
                rm -f "$flag"
            fi
        fi
    done < <(bt_list Connected)

    if   [ -n "$joined" ];    then label="$joined"
    elif [ "$count" -gt 0 ];  then label="$count"
    else                           label="on"
    fi

    if [ "$count" -gt 0 ]; then
        [ "$lowest" -le 20 ] && low=true
        [ "$lowest" -le 10 ] && crit=true
        emit connected "$label" "$low" "$crit"
    else
        emit on "$label" false false
    fi
}

while :; do
    kill -0 "$YPID" 2>/dev/null || exit 0      # yambar is gone: stop
    collect
    sleep "$INTERVAL" & sp=$!
    wait "$sp"
    kill "$sp" 2>/dev/null
done
EOF

    # ---- wofi menu: scan / pair / connect / disconnect / forget -----------
    put 755 "$CHROOT/usr/local/bin/cephalo-bt-menu" <<'EOF'
#!/usr/bin/env bash
# Bluetooth manager driven by wofi. Bound to the yambar Bluetooth module (left click) and Super+B.
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

# ---------------------------------------------------------------------------
# Wi-Fi: yambar status module + wofi network menu (NetworkManager / nmcli)
# ---------------------------------------------------------------------------
configure_wifi() {
    log "Installing Wi-Fi helpers"

    # ---- yambar module: connection status ---------------------------------
    put 755 "$CHROOT/usr/local/bin/cephalo-wifi-status" <<'EOF'
#!/usr/bin/env bash
# yambar "script" module, continuous mode. Prints a tag set whenever something
# changes:  state (wifi|ethernet|connecting|disconnected|off|missing)  label
# cephalo-wifi-menu sends SIGUSR1 to refresh immediately.

INTERVAL=5
YPID=$PPID

trap 'exit 0' TERM INT HUP
trap ':' USR1                      # just wakes the sleep below

last=""
# emit STATE LABEL   (only prints when something changed)
emit() {
    local out nl=$'\n' lbl="${2//[|$'\n']/ }"
    out="state|string|$1${nl}label|string|${lbl}"
    [ "$out" = "$last" ] && return 0
    last="$out"
    printf '%s\n\n' "$out"
}

wifi_ssid() {
    local line rest ssid
    line="$(nmcli -t -f ACTIVE,SIGNAL,SSID device wifi list --rescan no 2>/dev/null | grep -m1 '^yes:')"
    rest="${line#yes:}"
    ssid="${rest#*:}"
    ssid="${ssid//\\:/:}"                    # nmcli escapes ':' in terse mode
    printf '%s' "${ssid:-Wi-Fi}"
}

collect() {
    local running radio dev type st have_wifi=0 wifi_st="" eth_st=""

    running="$(nmcli -t -f RUNNING general 2>/dev/null)"
    if [ "$running" != running ]; then emit missing "no NetworkManager"; return; fi

    radio="$(nmcli radio wifi 2>/dev/null)"
    while IFS=: read -r dev type st; do
        case "$type" in
            wifi)
                have_wifi=1
                case "$st" in
                    connected*)  wifi_st=connected ;;
                    connecting*) [ "$wifi_st" = connected ] || wifi_st=connecting ;;
                    *)           [ -n "$wifi_st" ] || wifi_st="$st" ;;
                esac ;;
            ethernet)
                case "$st" in connected*) eth_st=connected ;; esac ;;
        esac
    done < <(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null)

    if   [ "$wifi_st" = connected ];                     then emit wifi "$(wifi_ssid)"
    elif [ "$eth_st" = connected ];                      then emit ethernet "Wired"
    elif [ "$have_wifi" = 0 ];                           then emit missing "No Wi-Fi"
    elif [ "$radio" = disabled ] || [ "$wifi_st" = unavailable ]; then emit off "Wi-Fi off"
    elif [ "$wifi_st" = connecting ];                    then emit connecting "Connecting..."
    else                                                      emit disconnected "Not connected"
    fi
}

while :; do
    kill -0 "$YPID" 2>/dev/null || exit 0      # yambar is gone: stop
    collect
    sleep "$INTERVAL" & sp=$!
    wait "$sp"
    kill "$sp" 2>/dev/null
done
EOF

    # ---- wofi menu: on/off / rescan / connect / disconnect / forget -------
    put 755 "$CHROOT/usr/local/bin/cephalo-wifi-menu" <<'EOF'
#!/usr/bin/env bash
# Wi-Fi manager driven by wofi + NetworkManager (nmcli).
# Bound to the yambar Wi-Fi module (left click) and Super+W.

SCAN_WAIT=3
WOFI=(wofi --dmenu --insensitive --cache-file /dev/null --width 560 --lines 14)

L_ON="Turn Wi-Fi ON"
L_OFF="Turn Wi-Fi OFF"
L_SCAN="Rescan for networks"
L_ADV="Advanced settings (connection editor)"
L_NONE="(no networks found - choose Rescan)"

pick() { "${WOFI[@]}" --prompt "$1"; }

note() {
    command -v notify-send >/dev/null 2>&1 && notify-send -a Wi-Fi -t 5000 "$1" "${2:-}"
    return 0
}

# Wake cephalo-wifi-status (the yambar script module) so the bar refreshes now.
poke_bar() { pkill -USR1 -f /usr/local/bin/cephalo-wifi-status 2>/dev/null; return 0; }

radio_on()     { [ "$(nmcli radio wifi 2>/dev/null)" = enabled ]; }
have_adapter() { nmcli -t -f TYPE device status 2>/dev/null | grep -qx wifi; }

set_power() {
    if [ "$1" = on ]; then
        rfkill unblock wifi 2>/dev/null
        nmcli radio wifi on >/dev/null 2>&1
        sleep 2
    else
        nmcli radio wifi off >/dev/null 2>&1
        sleep 0.5
    fi
    poke_bar
}

do_scan() {
    note "Scanning for networks" "This takes a few seconds."
    nmcli device wifi rescan >/dev/null 2>&1
    sleep "$SCAN_WAIT"
}

# Fills NET_LINES (the menu text) plus the parallel arrays NET_SSID, NET_ACTIVE,
# NET_SAVED and NET_SECURE, so a chosen line can be mapped back to its network.
build_networks() {
    NET_LINES=(); NET_SSID=(); NET_ACTIVE=(); NET_SAVED=(); NET_SECURE=()
    local nl=$'\n' saved seen="$nl" line inuse rest sig sec ssid mark state entry act sv se

    saved="$(nmcli -t -f TYPE,NAME connection show 2>/dev/null |
             sed -n -e 's/^802-11-wireless://p' -e 's/^wifi://p' | sed 's/\\:/:/g')"
    saved="$nl$saved$nl"

    # Active network first, then strongest signal first.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        inuse="${line%%:*}"; rest="${line#*:}"
        sig="${rest%%:*}";   rest="${rest#*:}"
        sec="${rest%%:*}";   ssid="${rest#*:}"
        ssid="${ssid//\\:/:}"
        [ -n "$ssid" ] || continue                        # hidden network
        case "$seen" in *"$nl$ssid$nl"*) continue ;; esac # one entry per SSID
        seen+="$ssid$nl"

        act=0; sv=0; se=0
        [ "$inuse" = "*" ] && act=1
        [ -n "$sec" ] && [ "$sec" != "--" ] && se=1
        case "$saved" in *"$nl$ssid$nl"*) sv=1 ;; esac

        if   [ "$act" = 1 ]; then mark="●"; state="connected"
        elif [ "$sv"  = 1 ]; then mark="○"; state="saved"
        elif [ "$se"  = 1 ]; then mark="+"; state="secured"
        else                      mark="+"; state="open"
        fi
        printf -v entry '%s  %s   [%s, %s%%]' "$mark" "$ssid" "$state" "$sig"

        NET_LINES+=("$entry"); NET_SSID+=("$ssid")
        NET_ACTIVE+=("$act");  NET_SAVED+=("$sv"); NET_SECURE+=("$se")
    done < <(nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID device wifi list --rescan no 2>/dev/null |
             LC_ALL=C sort -t: -k1,1r -k2,2nr)
}

do_connect() {
    local i="$1" ssid pw="" out rc hint=""
    ssid="${NET_SSID[i]}"

    if [ "${NET_SAVED[i]}" = 1 ]; then
        note "Connecting to $ssid" "Please wait..."
        out="$(nmcli -w 30 connection up id "$ssid" 2>&1)"; rc=$?
        hint=" If the password changed, choose Forget and connect again."
    else
        if [ "${NET_SECURE[i]}" = 1 ]; then
            pw="$(printf '' | wofi --dmenu --password --cache-file /dev/null \
                    --width 560 --lines 1 --prompt "Password for $ssid")" || return 0
            [ -n "$pw" ] || return 0
        fi
        note "Connecting to $ssid" "Please wait..."
        # NOTE: nmcli only takes the password as an argument, so it is briefly
        # visible in the process list of this machine.
        if [ -n "$pw" ]; then
            out="$(nmcli -w 30 device wifi connect "$ssid" password "$pw" 2>&1)"; rc=$?
        else
            out="$(nmcli -w 30 device wifi connect "$ssid" 2>&1)"; rc=$?
        fi
        # A failed attempt can leave a half-made profile; drop it so a retry starts clean.
        [ "$rc" -eq 0 ] || nmcli connection delete id "$ssid" >/dev/null 2>&1
    fi

    if [ "$rc" -eq 0 ]; then
        note "Connected" "$ssid"
    else
        note "Could not connect to $ssid" "$(head -n1 <<<"$out")$hint"
    fi
    poke_bar
}

do_disconnect() {
    local dev
    dev="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi" {print $1; exit}')"
    [ -n "$dev" ] && nmcli device disconnect "$dev" >/dev/null 2>&1
    note "Disconnected" "$1"
    poke_bar
}

do_forget() {
    nmcli connection delete id "$1" >/dev/null 2>&1
    note "Forgot network" "$1"
    poke_bar
}

network_menu() {
    local i="$1" ssid act sv choice
    local -a opts
    ssid="${NET_SSID[i]}"; act="${NET_ACTIVE[i]}"; sv="${NET_SAVED[i]}"

    if   [ "$act" = 1 ]; then opts=("Disconnect" "Forget this network" "Back")
    elif [ "$sv"  = 1 ]; then opts=("Connect" "Forget this network" "Back")
    else                      opts=("Connect" "Back")
    fi

    choice="$(printf '%s\n' "${opts[@]}" | pick "$ssid")" || return 0
    case "$choice" in
        "Connect")              do_connect "$i" ;;
        "Disconnect")           do_disconnect "$ssid" ;;
        "Forget this network")  do_forget "$ssid" ;;
    esac
}

main_menu() {
    local choice i
    while :; do
        if ! have_adapter; then
            note "No Wi-Fi adapter found" "Is NetworkManager running and the adapter's driver/firmware loaded?"
            exit 1
        fi

        if radio_on; then
            build_networks
            choice="$({
                printf '%s\n' "$L_OFF" "$L_SCAN"
                if [ "${#NET_LINES[@]}" -gt 0 ]; then printf '%s\n' "${NET_LINES[@]}"; else printf '%s\n' "$L_NONE"; fi
                printf '%s\n' "$L_ADV"
            } | pick "Wi-Fi")" || exit 0
        else
            choice="$(printf '%s\n' "$L_ON" "$L_ADV" | pick "Wi-Fi is off")" || exit 0
        fi

        case "$choice" in
            "$L_ON")   set_power on ;;
            "$L_OFF")  set_power off ;;
            "$L_SCAN") do_scan ;;
            "$L_NONE") ;;
            "$L_ADV")  setsid nm-connection-editor >/dev/null 2>&1 & exit 0 ;;
            *)
                for ((i = 0; i < ${#NET_LINES[@]}; i++)); do
                    if [ "${NET_LINES[i]}" = "$choice" ]; then network_menu "$i"; break; fi
                done
                ;;
        esac
    done
}

main_menu
EOF

    log "Wi-Fi configuration written"
}

# ---------------------------------------------------------------------------
# Wallpaper: per-monitor, resolution-matched (cephalo-wallpaper + swaybg + wlr-randr)
# ---------------------------------------------------------------------------
configure_wallpaper() {
    log "Installing wallpaper helper"

    {
        echo "# Cephalo wallpaper settings. Override per user in ~/.config/cephalo/wallpaper.conf"
        echo "# Files are <WALLPAPER_NAME>_<W>x<H>.png under WALLPAPER_BASE_URL."
        printf 'WALLPAPER_NAME="%s"\n' "$WALLPAPER_NAME"
        printf 'WALLPAPER_BASE_URL="%s"\n' "$WALLPAPER_BASE_URL"
        echo "# fill | fit | stretch | center | tile"
        echo 'WALLPAPER_MODE="fill"'
    } | put 644 "$CHROOT/etc/cephalo/wallpaper.conf"

    put 755 "$CHROOT/usr/local/bin/cephalo-wallpaper" <<'EOF'
#!/usr/bin/env bash
# cephalo-wallpaper: give every monitor the wallpaper size that fits it best.
#
#   cephalo-wallpaper           run (started from the labwc autostart). Starts swaybg with
#                               one image per monitor, downloads sizes it does not have yet
#                               (once online; retries as soon as a connection comes up) and
#                               keeps watching for monitors being plugged in / unplugged /
#                               changing mode. If it is already
#                               running, it tells that instance to re-apply and exits.
#   cephalo-wallpaper --print   show what would be used for each monitor, then exit
#
# Config (later file wins): /etc/cephalo/wallpaper.conf, ~/.config/cephalo/wallpaper.conf
#   WALLPAPER_NAME      file prefix, files are  <name>_<W>x<H>.png
#   WALLPAPER_BASE_URL  where the files are downloaded from
#   WALLPAPER_MODE      fill (default) | fit | stretch | center | tile
#   POLL_SECONDS        how often to look for monitor changes (default 5)

# Every size that exists. Keep in sync with the wallpaper repo.
RES_LIST="
1280x720 1366x768 1600x900 1920x1080 2560x1440 3840x2160 5120x2880 7680x4320
1280x800 1440x900 1680x1050 1920x1200 2560x1600 2880x1800 3840x2400
2256x1504 2880x1920 3000x2000
2560x1080 3440x1440 3840x1600 5120x2160
3840x1080 5120x1440 7680x2160
1280x1024 1600x1200 1024x768
"

SYS_DIR="${CEPHALO_WP_SYS_DIR:-/usr/share/backgrounds/cephalo}"
GRADIENT="${CEPHALO_WP_GRADIENT:-/usr/share/backgrounds/cephalo-gradient.png}"
CACHE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/cephalo/wallpapers"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}"

WALLPAPER_NAME=humble_lightripple
WALLPAPER_BASE_URL=""
WALLPAPER_MODE=fill
POLL_SECONDS=5
FALLBACK_COLOR=1e1e2e
FAIL_BACKOFF_MIN=10

say() { echo "cephalo-wallpaper: $*" >&2; }

load_config() {
    local f
    for f in /etc/cephalo/wallpaper.conf "${XDG_CONFIG_HOME:-$HOME/.config}/cephalo/wallpaper.conf"; do
        [ -r "$f" ] && . "$f"
    done
    RES_LIST="${RES_LIST//$'\n'/ }"
}

# "NAME WIDTH HEIGHT" per enabled monitor: the current mode in physical pixels,
# swapped for rotated (portrait) monitors.
outputs() {
    wlr-randr 2>/dev/null | awk '
        function flush() {
            if (name != "" && enabled && w > 0) {
                if (tf ~ /^(90|270|flipped-90|flipped-270)$/) { t = w; w = h; h = t }
                print name, w, h
            }
            name = ""
        }
        /^[^[:space:]]/            { flush(); name = $1; enabled = 1; w = 0; h = 0; tf = "normal"; next }
        /^[[:space:]]+Enabled:/    { enabled = ($2 == "yes"); next }
        /^[[:space:]]+Transform:/  { tf = $2; next }
        /^[[:space:]]+[0-9]+x[0-9]+ px,/ && /current/ { split($1, a, "x"); w = a[1]; h = a[2]; next }
        END { flush() }'
}

# pick_res WIDTH HEIGHT "LIST OF WxH"  ->  the entry that suits that monitor best:
#   1. an exact match;
#   2. otherwise the closest aspect ratio (ratios within ~3% count as the same);
#   3. within that ratio, the smallest image that still covers the monitor
#      (so it is only ever scaled down), or the largest one if none is big enough.
pick_res() {
    awk -v W="$1" -v H="$2" -v list="$3" 'BEGIN {
        n = split(list, c, " ")
        for (i = 1; i <= n; i++) if (c[i] == W "x" H) { print c[i]; exit }
        L = (W > H) ? W : H; S = (W > H) ? H : W; ta = L / S      # orientation-free ratio
        mind = 1e9
        for (i = 1; i <= n; i++) {
            split(c[i], p, "x"); d = log((p[1] / p[2]) / ta); if (d < 0) d = -d
            dist[i] = d; if (d < mind) mind = d
        }
        for (i = 1; i <= n; i++) {
            if (dist[i] > mind + 0.03) continue
            split(c[i], p, "x"); area = p[1] * p[2]
            if (p[1] >= W && p[2] >= H) { if (up == "" || area < upa) { up = c[i]; upa = area } }
            else                        { if (dn == "" || area > dna) { dn = c[i]; dna = area } }
        }
        print (up != "") ? up : dn
    }'
}

# Path of the local copy of one size (download cache first, then any copy placed system-wide in SYS_DIR).
local_file() {
    local f
    for f in "$CACHE_DIR/${WALLPAPER_NAME}_$1.png" "$SYS_DIR/${WALLPAPER_NAME}_$1.png"; do
        [ -s "$f" ] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

avail_list() {
    local r
    for r in $RES_LIST; do
        local_file "$r" >/dev/null && printf '%s ' "$r"
    done
}

# One tab-separated line per monitor:  NAME  WxH  wanted-size  size-used-now  file-used-now
# ("-" when nothing is downloaded yet).
make_plan() {
    local avail name w h want use file
    avail="$(avail_list)"
    while read -r name w h; do
        [ -n "$name" ] || continue
        want="$(pick_res "$w" "$h" "$RES_LIST")"
        use=""; file=""
        if [ -n "$avail" ]; then
            use="$(pick_res "$w" "$h" "$avail")"
            [ -n "$use" ] && file="$(local_file "$use")"
        fi
        printf '%s\t%sx%s\t%s\t%s\t%s\n' "$name" "$w" "$h" "$want" "${use:--}" "${file:--}"
    done < <(outputs)
}

# Image for monitors we have no plan for (e.g. one that was just plugged in).
default_image() {
    local f
    f="$(compgen -G "$SYS_DIR/${WALLPAPER_NAME}_*.png" | head -n1)"
    [ -n "$f" ] || f="$(compgen -G "$CACHE_DIR/${WALLPAPER_NAME}_*.png" | head -n1)"
    [ -n "$f" ] || { [ -s "$GRADIENT" ] && f="$GRADIENT"; }
    printf '%s' "$f"
}

# True when NetworkManager reports a working connection (if there is no nmcli we
# cannot tell, so assume we are online and let the download itself decide).
online() {
    command -v nmcli >/dev/null 2>&1 || return 0
    [ "$(nmcli -t -f STATE general 2>/dev/null)" = connected ]
}

# Download one size in the background (at most one download per size at a time, and
# a failed size is not retried for FAIL_BACKOFF_MIN minutes).
start_fetch() {
    local res="$1" lock="$CACHE_DIR/.lock-$1" fail="$CACHE_DIR/.fail-$1"
    [ -n "$WALLPAPER_BASE_URL" ] || return 0
    command -v wget >/dev/null 2>&1 || return 0
    if [ -e "$fail" ] && [ -z "$(find "$fail" -mmin +"$FAIL_BACKOFF_MIN" 2>/dev/null)" ]; then
        return 0
    fi
    mkdir "$lock" 2>/dev/null || return 0
    (
        tmp="$CACHE_DIR/.dl-$res.$$"
        url="$WALLPAPER_BASE_URL/${WALLPAPER_NAME}_${res}.png"
        say "downloading ${WALLPAPER_NAME}_${res}.png"
        if wget -q --timeout=20 --tries=2 -O "$tmp" "$url" \
           && [ "$(head -c4 "$tmp" | tail -c3)" = PNG ]; then
            mv -f "$tmp" "$CACHE_DIR/${WALLPAPER_NAME}_${res}.png"
            rm -f "$fail"
            say "got ${WALLPAPER_NAME}_${res}.png"
        else
            rm -f "$tmp"; : > "$fail"
            say "could not download $url (will retry in $FAIL_BACKOFF_MIN min)"
        fi
        rmdir "$lock"
    ) 9>&- >/dev/null &
}

# (Re)start swaybg for the given plan; the new one is up before the old one goes.
apply() {
    local plan="$1" name mode want use file img new
    local -a args=()
    while IFS=$'\t' read -r name mode want use file; do
        [ -n "$name" ] || continue
        if [ "$file" != "-" ]; then
            args+=(-o "$name" -i "$file" -m "$WALLPAPER_MODE" -c "$FALLBACK_COLOR")
            say "$name ($mode): $(basename "$file")"
        else
            say "$name ($mode): nothing downloaded yet, using the default background"
        fi
    done <<<"$plan"

    img="$(default_image)"
    if [ -n "$img" ]; then
        args+=(-o '*' -i "$img" -m "$WALLPAPER_MODE" -c "$FALLBACK_COLOR")
    else
        args+=(-o '*' -c "$FALLBACK_COLOR")
    fi

    swaybg "${args[@]}" 9>&- >/dev/null &
    new=$!
    sleep 0.4
    if [ -n "$SWAYBG_PID" ]; then
        kill "$SWAYBG_PID" 2>/dev/null
        wait "$SWAYBG_PID" 2>/dev/null
    fi
    SWAYBG_PID=$new
}

print_plan() {
    local plan name mode want use file state
    plan="$(make_plan)"
    if [ -z "$plan" ]; then
        echo "No monitors detected (needs wlr-randr and a running Wayland session)."
        return 1
    fi
    while IFS=$'\t' read -r name mode want use file; do
        if local_file "$want" >/dev/null; then state="on disk"
        else state="not downloaded yet, showing ${use}"; fi
        printf '%-14s %-10s -> %-10s (%s)\n' "$name" "$mode" "$want" "$state"
    done <<<"$plan"
}

cleanup() {
    [ -n "$SWAYBG_PID" ] && kill "$SWAYBG_PID" 2>/dev/null
    rm -f "$RUNTIME/cephalo-wallpaper.pid"
}

main() {
    local plan name mode want use file warned=0 pid
    case "${1:-}" in
        --print|-p) load_config; print_plan; exit $? ;;
        -h|--help)  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac

    command -v swaybg >/dev/null 2>&1 || { say "swaybg is not installed"; exit 1; }
    mkdir -p "$CACHE_DIR"

    # Only one instance; a second invocation just asks the first to re-apply.
    exec 9>"$RUNTIME/cephalo-wallpaper.lock"
    if ! flock -n 9; then
        pid="$(cat "$RUNTIME/cephalo-wallpaper.pid" 2>/dev/null)"
        [ -n "$pid" ] && kill -USR1 "$pid" 2>/dev/null
        exit 0
    fi
    echo $$ > "$RUNTIME/cephalo-wallpaper.pid"
    rm -rf "$CACHE_DIR"/.lock-* "$CACHE_DIR"/.dl-* 2>/dev/null   # leftovers of a killed run

    SWAYBG_PID=""
    was_online=0
    last="__none__"
    trap 'last=__none__' USR1            # wakes the sleep below and forces a re-apply
    trap 'exit 0' TERM INT HUP
    trap cleanup EXIT

    while :; do
        load_config
        plan="$(make_plan)"
        if [ -z "$plan" ] && [ "$warned" = 0 ]; then
            say "no monitors detected (is wlr-randr installed?); using the default image everywhere"
            warned=1
        fi

        # Fetch any size we want but do not have yet, but only while online. When a
        # connection comes up, forget earlier failures so we retry straight away.
        if online; then
            if [ "$was_online" = 0 ]; then
                rm -f "$CACHE_DIR"/.fail-* 2>/dev/null
                was_online=1
            fi
            while IFS=$'\t' read -r name mode want use file; do
                [ -n "$want" ] || continue
                local_file "$want" >/dev/null || start_fetch "$want"
            done <<<"$plan"
        else
            was_online=0
        fi

        # (re)apply on first run, a monitor/file change, a poke, or if swaybg died
        if [ "$plan" != "$last" ] \
           || { [ -n "$SWAYBG_PID" ] && ! kill -0 "$SWAYBG_PID" 2>/dev/null; }; then
            apply "$plan"
            last="$plan"
        fi

        sleep "$POLL_SECONDS" 9>&- & sp=$!
        wait "$sp"
        kill "$sp" 2>/dev/null
    done
}

main "$@"
EOF

    log "Wallpaper configuration written"
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

    ui_msg "Welcome to the Cephalo installer.\n\nThis will erase a disk of your choice and install Cephalo on it.\nThe system is downloaded and built from the Debian mirror, so a network connection is required and the install takes a while.\n\nDetected boot mode: $BOOT_MODE"

    ensure_network
    select_disk
    detect_hardware
    resolve_kernel
    [ -n "$KERNEL_URL" ] || [ -d "$PAYLOAD_DIR/kernel" ] \
        || die "Could not download a kernel and none is bundled at $PAYLOAD_DIR/kernel. Check the network and retry."
    show_hw_summary
    prompt_system_settings
    confirm_erase

    partition_disk
    mount_target_root
    debootstrap_base
    mount_target_esp
    write_fstab
    mount_chroot
    prepare_custom_kernel
    prepare_splash
    write_hw_report
    write_chroot_script
    run_chroot_setup
    configure_bluetooth
    configure_wifi
    configure_wallpaper
    configure_drive
    check_kernel_bluetooth
    check_kernel_splash
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

detect_only() {
    if [ -z "$INSTALL_DISK" ]; then
        INSTALL_DISK="$(lsblk -dnpo NAME,TYPE | awk '$2=="disk" && $1 !~ /\/(zram|ram|nbd|loop|fd)[0-9]*$/ {print $1; exit}')"
    fi
    [ -n "$INSTALL_DISK" ] || die "no disk found"
    detect_hardware
    resolve_kernel
    echo; hw_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
case "${1:-install}" in
    install)         install_main ;;
    detect)          detect_only ;;
    -h|--help|help)  usage ;;
    *)               usage >&2; die "unknown argument: $1" ;;
esac
fi
