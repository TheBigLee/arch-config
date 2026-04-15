# dotfiles

Reproducible Arch Linux setup for two machines:

| Machine | Hardware |
|---------|----------|
| **Thor** | Desktop, Nvidia RTX 4080 |
| **Freya** | Lenovo ThinkPad X1 |

## Overview

Four layers, each with a clear scope:

```
pre-install.sh      Run once from Arch ISO — pacstrap + chroot config
install.sh          Run once after first boot — wires everything together
ansible/            Idempotent system config — re-run any time
chezmoi             Dotfiles — re-apply any time with chezmoi apply
```

## Full setup flow

### 1. From the Arch ISO

Partition your disks, then set up LUKS + LVM manually:

```bash
# Open LUKS
cryptsetup open /dev/<luks-part> cryptroot

# LVM inside LUKS
pvcreate /dev/mapper/cryptroot
vgcreate vg0 /dev/mapper/cryptroot
lvcreate -L 60G vg0 -n root
lvcreate -l 100%FREE vg0 -n home

# Format
mkfs.ext4 /dev/vg0/root      # or btrfs, xfs, etc.
mkfs.ext4 /dev/vg0/home
mkfs.fat -F32 /dev/<efi-part>

# Mount — note /efi not /boot
mount /dev/vg0/root /mnt
mkdir -p /mnt/{efi,home,boot}
mount /dev/vg0/home /mnt/home
mount /dev/<efi-part> /mnt/efi
```

Then run the pre-install script:

```bash
curl -O https://raw.githubusercontent.com/TheBigLee/dotfiles/main/pre-install.sh
# Edit the variables at the top (LUKS_PART, EFI_PART, LVM_VG, HOSTNAME, USERNAME, ...)
vim pre-install.sh
bash pre-install.sh
```

What it does:
- `pacstrap` — base, linux, lvm2, efibootmgr, sbctl
- `mkinitcpio` — `encrypt` + `lvm2` hooks, UKI output to `/efi/EFI/Linux/`
- `/etc/kernel/cmdline` — `rd.luks.name=<uuid>=cryptroot root=/dev/vg0/root`
- `efibootmgr` — UEFI boot entries pointing directly to the UKIs (no bootloader)
- Creates user, enables NetworkManager, clones this repo

```bash
umount -R /mnt && reboot
```

---

### 2. After first boot

```bash
cd ~/dotfiles
bash install.sh
```

What it does, in order:

| Step | What happens |
|------|-------------|
| Install base deps | `pacman -S git base-devel ansible` |
| Install paru | Builds from AUR if not present |
| Install chezmoi | Via paru |
| Clone dotfiles | Pulls this repo if not already present |
| Install pacman hook | Auto-updates `pkglist.txt` / `aur-pkglist.txt` after every transaction |
| Run Ansible | `ansible-playbook -i inventory setup.yml --limit $(hostname)` |
| Apply chezmoi | `chezmoi init --source ~/dotfiles --apply` |
| Run Hyprland installer | Interactive — see note below |

> **Hyprland installer note:** The [Arch-Hyprland](https://github.com/LinuxBeginnings/Arch-Hyprland)
> installer uses whiptail dialogs. When the options checklist appears, refer to
> `~/Arch-Hyprland/preset.conf` — Ansible writes this file with the right ON/OFF
> values for your machine.

---

### 3. Enable Secure Boot

After `install.sh` completes, the `secureboot` Ansible role will have:
- Generated custom Secure Boot keys with `sbctl`
- Enrolled them (including Microsoft CA for hardware firmware compatibility)
- Signed all UKIs in `/efi/EFI/Linux/`

Reboot into UEFI firmware setup and **enable Secure Boot**.

To verify afterwards:

```bash
sbctl status      # should show: Secure Boot enabled, Setup Mode off
sbctl verify      # all files should show ✓
```

From this point on, `sbctl` re-signs UKIs automatically via its pacman hook whenever the kernel is updated.

---

## Adding a new machine

**1.** Add it to `ansible/inventory`:

```ini
[desktops]
Thor     ansible_connection=local
NewHost  ansible_connection=local
```

**2.** Create `ansible/host_vars/NewHost.yml`:

```yaml
hostname: NewHost
timezone: Europe/Zurich

extra_pacman_packages: []
extra_aur_packages: []
extra_services_enable: []

hyprland_option_overrides:
  bluetooth: "OFF"
  nvidia: "OFF"
```

**3.** Run `pre-install.sh` on the new machine with `HOSTNAME=NewHost`, then `install.sh`.

---

## Day-to-day usage

### Packages

Packages are tracked automatically. After any `pacman -S` or `pacman -R`, the hook updates:
- `pkglist.txt` — explicit pacman packages (`pacman -Qqe`)
- `aur-pkglist.txt` — AUR packages (`pacman -Qqm`)

Commit and push these files to keep the repo current.

To restore packages on a new system:

```bash
pacman -S --needed - < pkglist.txt
paru -S --needed - < aur-pkglist.txt
```

### Dotfiles

```bash
chezmoi diff          # see what's changed since last apply
chezmoi add ~/.config/foo/bar.conf    # track a new config file
chezmoi apply         # apply repo → machine
chezmoi cd            # jump to the chezmoi source directory
```

Machine-specific config goes in `.chezmoi.toml.tmpl` — the `machine_type` variable
is set based on hostname and can be used to template any managed file.

### Re-running Ansible

Ansible is idempotent — safe to re-run any time to drift back to desired state:

```bash
cd ~/dotfiles/ansible
ansible-playbook -i inventory setup.yml --limit "$(hostname)" --ask-become-pass
```

To run only specific roles:

```bash
ansible-playbook -i inventory setup.yml --limit "$(hostname)" --tags services --ask-become-pass
```

---

## Repository structure

```
dotfiles/
├── pre-install.sh              # Phase 1: pacstrap + chroot config (run from ISO)
├── install.sh                  # Phase 2: post-boot bootstrap
├── .chezmoi.toml.tmpl          # chezmoi machine config template
├── pkglist.txt                 # auto-updated by pacman hook
├── aur-pkglist.txt             # auto-updated by pacman hook
├── pacman-hooks/
│   └── pkglist.hook            # installed to /etc/pacman.d/hooks/
└── ansible/
    ├── setup.yml               # main playbook
    ├── inventory               # machine list
    ├── vars/
    │   └── packages.yml        # shared defaults (packages, services, hyprland options)
    ├── host_vars/
    │   ├── Thor.yml            # desktop overrides
    │   └── Freya.yml           # laptop overrides
    └── roles/
        ├── base/               # pacman packages, locale, timezone, hostname, shell
        ├── aur/                # paru AUR installs
        ├── services/           # systemd enable/disable
        ├── hardware/           # auto-detects CPU/GPU, installs microcode + drivers
        ├── secureboot/         # sbctl key enrollment + UKI signing
        └── hyprland/           # clones Arch-Hyprland, writes preset.conf
```
