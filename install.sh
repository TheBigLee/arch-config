#!/usr/bin/env bash
# Bootstrap script for reproducible Arch Linux setup
# Run on a fresh Arch install after base system configuration (locale, timezone, users, etc.)
set -euo pipefail

CONFIG_REPO="${CONFIG_REPO:-https://github.com/TheBigLee/arch-config}"
CONFIG_DIR="$HOME/arch-config"
CHEZMOI_REPO="${CHEZMOI_REPO:-https://github.com/TheBigLee/dot-chezmoi}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

require_non_root() {
    [[ $EUID -ne 0 ]] || error "Do not run this script as root. It will use sudo where needed."
}

install_base_deps() {
    info "Installing base dependencies..."
    sudo pacman -Sy --needed --noconfirm git base-devel ansible
}

install_paru() {
    if command -v paru &>/dev/null; then
        info "paru already installed, skipping."
        return
    fi
    info "Installing paru (AUR helper)..."
    local tmp
    tmp=$(mktemp -d)
    git clone https://aur.archlinux.org/paru.git "$tmp/paru"
    (cd "$tmp/paru" && makepkg -si --noconfirm)
    rm -rf "$tmp"
}

install_chezmoi() {
    if command -v chezmoi &>/dev/null; then
        info "chezmoi already installed, skipping."
        return
    fi
    info "Installing chezmoi..."
    paru -S --needed --noconfirm chezmoi
}

clone_config() {
    if [[ -d "$CONFIG_DIR/.git" ]]; then
        info "Config repo already present at $CONFIG_DIR, pulling latest..."
        git -C "$CONFIG_DIR" pull
    else
        info "Cloning config repo from $CONFIG_REPO..."
        git clone "$CONFIG_REPO" "$CONFIG_DIR"
    fi
}

run_ansible() {
    info "Running Ansible playbook for host: $(cat /etc/hostname)..."
    cd "$CONFIG_DIR/ansible"
    ansible-playbook -i inventory setup.yml --limit "$(cat /etc/hostname)" --ask-become-pass
}

run_hyprland_installer() {
    local hypr_dir="$HOME/Arch-Hyprland"
    local preset="$hypr_dir/preset.conf"

    if [[ ! -d "$hypr_dir" ]]; then
        warn "Arch-Hyprland not found at $hypr_dir — Ansible hyprland role may have failed."
        return 1
    fi

    echo
    info "=== Arch-Hyprland interactive installer ==="
    info "Preset written to: $preset"
    info "The installer uses whiptail dialogs. When the options checklist appears,"
    info "check the boxes that match the ON/OFF values in $preset"
    echo
    warn "Make sure you have run a full system update and rebooted before this step."
    echo
    read -rp "Press ENTER to launch the Arch-Hyprland installer, or Ctrl+C to skip..."

    cd "$hypr_dir"
    bash install.sh --preset preset.conf
}

apply_chezmoi() {
    info "Applying chezmoi dotfiles from $CHEZMOI_REPO..."
    chezmoi init --apply "$CHEZMOI_REPO"
}

install_pacman_hook() {
    info "Installing pacman hook for package list tracking..."
    sudo install -Dm644 "$CONFIG_DIR/pacman-hooks/pkglist.hook" \
        /etc/pacman.d/hooks/pkglist.hook
}

main() {
    require_non_root

    info "=== Arch Linux reproducible setup bootstrap ==="
    info "Config repo:  $CONFIG_REPO"
    info "Chezmoi repo: $CHEZMOI_REPO"
    echo

    install_base_deps
    install_paru
    install_chezmoi
    clone_config
    install_pacman_hook
    run_ansible
    apply_chezmoi
    run_hyprland_installer

    echo
    info "=== Bootstrap complete! ==="
    info "Reboot to enter Hyprland via SDDM."
    warn "Remember to push updated pkglist.txt and aur-pkglist.txt to your repo."
}

main "$@"
