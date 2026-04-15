#!/usr/bin/env bash
# Pre-install script for reproducible Arch Linux setup
# Run from the Arch ISO live environment AFTER you have manually:
#
#   # Open LUKS
#   cryptsetup open /dev/<luks-part> <LUKS_MAPPER>
#
#   # Set up LVM inside LUKS
#   pvcreate /dev/mapper/<LUKS_MAPPER>
#   vgcreate <LVM_VG> /dev/mapper/<LUKS_MAPPER>
#   lvcreate -L <size> <LVM_VG> -n root
#   lvcreate -l 100%FREE <LVM_VG> -n home
#
#   # Format
#   mkfs.<fs> /dev/<LVM_VG>/root
#   mkfs.<fs> /dev/<LVM_VG>/home
#   mkfs.fat -F32 /dev/<efi-part>
#
#   # Mount
#   mount /dev/<LVM_VG>/root /mnt
#   mkdir -p /mnt/{efi,home,boot}
#   mount /dev/<LVM_VG>/home /mnt/home
#   mount /dev/<efi-part> /mnt/efi     ← note: /efi not /boot
#
# What this script does:
#   - pacstrap base system into /mnt
#   - genfstab
#   - Configures from within chroot:
#       locale, timezone, hostname, users
#       mkinitcpio with encrypt + lvm2 hooks, UKI output to /efi/EFI/Linux/
#       kernel cmdline written to /etc/kernel/cmdline (embedded in UKI)
#       efibootmgr UEFI boot entry pointing directly to the UKI (no bootloader)
#       sbctl installed (Secure Boot key enrollment handled later by Ansible)
set -euo pipefail

# ==============================================================================
# CONFIGURATION — edit these before running
# ==============================================================================

# The raw LUKS partition (NOT the mapper — needed for UUID lookup and efibootmgr)
LUKS_PART="${LUKS_PART:-/dev/nvme0n1p2}"

# The EFI partition (needed for efibootmgr disk/partition derivation)
EFI_PART="${EFI_PART:-/dev/nvme0n1p1}"

# The name you opened the LUKS container with
LUKS_MAPPER="${LUKS_MAPPER:-cryptroot}"

# LVM volume group and root logical volume names
LVM_VG="${LVM_VG:-vg0}"
LVM_ROOT_LV="${LVM_ROOT_LV:-root}"

# System configuration
HOSTNAME="${HOSTNAME:-Thor}"
USERNAME="${USERNAME:-bigli}"
TIMEZONE="${TIMEZONE:-Europe/Zurich}"
LOCALE="${LOCALE:-en_US.UTF-8}"

# Dotfiles repo — cloned for the new user so install.sh is ready after reboot
DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/TheBigLee/arch-config.git}"

# ==============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Preflight checks
# ------------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || error "Run this script as root (from the Arch ISO)."

[[ -b "$LUKS_PART" ]] \
    || error "LUKS partition not found: $LUKS_PART"
[[ -b "$EFI_PART" ]] \
    || error "EFI partition not found: $EFI_PART"
[[ -b "/dev/mapper/$LUKS_MAPPER" ]] \
    || error "LUKS mapper /dev/mapper/$LUKS_MAPPER not found. Open it first:
  cryptsetup open $LUKS_PART $LUKS_MAPPER"
[[ -b "/dev/$LVM_VG/$LVM_ROOT_LV" ]] \
    || error "LVM root volume /dev/$LVM_VG/$LVM_ROOT_LV not found."
mountpoint -q /mnt \
    || error "/mnt is not mounted. Mount your root LV first."
mountpoint -q /mnt/efi \
    || error "/mnt/efi is not mounted. Mount your EFI partition at /mnt/efi."
mountpoint -q /mnt/home \
    || error "/mnt/home is not mounted. Mount your home LV first."

LUKS_UUID=$(blkid -s UUID -o value "$LUKS_PART") \
    || error "Could not read UUID from $LUKS_PART"

# Derive disk device and partition number for efibootmgr
EFI_DISK="/dev/$(lsblk -no pkname "$EFI_PART")"
EFI_PART_NUM=$(lsblk -no PARTN "$EFI_PART")

info "LUKS partition : $LUKS_PART  (UUID: $LUKS_UUID)"
info "LUKS mapper    : /dev/mapper/$LUKS_MAPPER"
info "LVM root       : /dev/$LVM_VG/$LVM_ROOT_LV"
info "EFI partition  : $EFI_PART  (disk: $EFI_DISK, part: $EFI_PART_NUM)"
info "Hostname       : $HOSTNAME"
info "Username       : $USERNAME"
info "Timezone       : $TIMEZONE"
echo

# ------------------------------------------------------------------------------
# Install base system
# ------------------------------------------------------------------------------

info "Running pacstrap..."
pacstrap -K /mnt \
    base base-devel linux linux-headers linux-firmware \
    lvm2 \
    efibootmgr \
    networkmanager \
    git \
    sudo \
    neovim \
    sbctl

info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# ------------------------------------------------------------------------------
# Chroot configuration
# ------------------------------------------------------------------------------

info "Entering chroot to configure system..."

arch-chroot /mnt /bin/bash -s \
    "$HOSTNAME" "$USERNAME" "$TIMEZONE" "$LOCALE" \
    "$LUKS_UUID" "$LUKS_MAPPER" "$LVM_VG" "$LVM_ROOT_LV" \
    "$EFI_DISK" "$EFI_PART_NUM" \
    "$DOTFILES_REPO" \
<< 'CHROOT'

HOSTNAME="$1"
USERNAME="$2"
TIMEZONE="$3"
LOCALE="$4"
LUKS_UUID="$5"
LUKS_MAPPER="$6"
LVM_VG="$7"
LVM_ROOT_LV="$8"
EFI_DISK="$9"
EFI_PART_NUM="${10}"
DOTFILES_REPO="${11}"

set -euo pipefail

# Timezone & hardware clock
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

# Locale
sed -i "s/^#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
printf '\n127.0.1.1\t%s\n' "$HOSTNAME" >> /etc/hosts

# Kernel cmdline — embedded into the UKI by mkinitcpio
# rd.luks.name=<uuid>=<name> identifies the device and sets the mapper name
mkdir -p /etc/kernel
cat > /etc/kernel/cmdline << EOF
rd.luks.name=${LUKS_UUID}=${LUKS_MAPPER} root=/dev/${LVM_VG}/${LVM_ROOT_LV} rw quiet loglevel=3
EOF

# mkinitcpio hooks: systemd base, sd-encrypt unlocks LUKS, lvm2 provides binaries
# (systemd activates the volume group automatically via udev rules)
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole sd-encrypt lvm2 filesystems fsck)/' \
    /etc/mkinitcpio.conf

# Configure mkinitcpio preset to produce Unified Kernel Images (UKIs)
# UKIs embed kernel + initramfs + cmdline into a single signed .efi binary
mkdir -p /efi/EFI/Linux

cat > /etc/mkinitcpio.d/linux.preset << 'EOF'
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"

PRESETS=('default' 'fallback')

# UKI output paths on the EFI partition
default_uki="/efi/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"

fallback_uki="/efi/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
EOF

mkinitcpio -P

# Register UEFI boot entries pointing directly to the UKIs (no bootloader)
efibootmgr --create \
    --disk "$EFI_DISK" \
    --part "$EFI_PART_NUM" \
    --label "Arch Linux" \
    --loader 'EFI\Linux\arch-linux.efi' \
    --unicode

efibootmgr --create \
    --disk "$EFI_DISK" \
    --part "$EFI_PART_NUM" \
    --label "Arch Linux (fallback)" \
    --loader 'EFI\Linux\arch-linux-fallback.efi' \
    --unicode

# Pacman hook: regenerate UKI when the kernel is updated.
# sbctl (run via Ansible post-boot) will also re-sign on each mkinitcpio run
# via its own hook once keys are enrolled.
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/90-mkinitcpio-install.hook << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux
Target = linux-headers

[Action]
Description = Updating Unified Kernel Image
When = PostTransaction
Exec = /usr/bin/mkinitcpio -P
EOF

# Root password
echo "--- Set root password ---"
passwd

# User
useradd -mG wheel,audio,video,storage,optical,input "$USERNAME"
echo "--- Set password for $USERNAME ---"
passwd "$USERNAME"

# Sudo for wheel group
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Services
systemctl enable NetworkManager

# Clone dotfiles so install.sh is ready after first reboot
if [[ "$DOTFILES_REPO" != *"YOUR_USERNAME"* ]]; then
    sudo -u "$USERNAME" git clone "$DOTFILES_REPO" "/home/${USERNAME}/dotfiles"
    echo "Dotfiles cloned to /home/${USERNAME}/dotfiles — run ~/dotfiles/install.sh after reboot."
else
    echo "DOTFILES_REPO not configured — set it at the top of pre-install.sh."
fi

echo ""
echo "Chroot configuration complete."
CHROOT

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------

echo
info "=== Pre-install complete ==="
info "Unmount and reboot:"
info "  umount -R /mnt && reboot"
echo
info "After booting into your new system:"
info "  1. Log in as $USERNAME"
info "  2. Run: ~/dotfiles/install.sh"
warn "Secure Boot is NOT yet active — enter UEFI setup and enable it after"
warn "sbctl has enrolled your keys (done automatically by the Ansible secureboot role)."
