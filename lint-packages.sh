#!/usr/bin/env python3
"""
Lint installed packages against ansible/vars/packages.yml + host_vars/<hostname>.yml.
Reports packages installed explicitly but not tracked in Ansible.
"""

import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("error: PyYAML not installed (pip install python-yaml)", file=sys.stderr)
    sys.exit(1)

REPO = Path(__file__).parent
VARS_FILE = REPO / "ansible/vars/packages.yml"

def get_hostname():
    result = subprocess.run(["hostnamectl", "hostname"], capture_output=True, text=True)
    if result.returncode == 0:
        return result.stdout.strip()
    return Path("/etc/hostname").read_text().strip()

def load_yaml(path):
    if not path.exists():
        return {}
    with open(path) as f:
        return yaml.safe_load(f) or {}

def installed_pacman():
    out = subprocess.run(["pacman", "-Qqe"], capture_output=True, text=True)
    return set(out.stdout.splitlines())

def installed_aur():
    out = subprocess.run(["pacman", "-Qqm"], capture_output=True, text=True)
    return set(out.stdout.splitlines())

def main():
    hostname = get_hostname()
    host_vars_file = REPO / f"ansible/host_vars/{hostname}.yml"

    base = load_yaml(VARS_FILE)
    host = load_yaml(host_vars_file)

    tracked_pacman = set(base.get("pacman_packages", []) + host.get("extra_pacman_packages", []))
    tracked_aur    = set(base.get("aur_packages", [])    + host.get("extra_aur_packages", []))

    inst_pacman = installed_pacman()
    inst_aur    = installed_aur()

    # AUR packages show up in both -Qqe and -Qqm; remove them from pacman set
    inst_pacman -= inst_aur

    untracked_pacman = inst_pacman - tracked_pacman
    untracked_aur    = inst_aur    - tracked_aur
    missing_pacman   = tracked_pacman - inst_pacman - inst_aur
    missing_aur      = tracked_aur - inst_aur

    ok = True

    if untracked_pacman:
        ok = False
        print("Installed but not tracked in packages.yml (pacman):")
        for p in sorted(untracked_pacman):
            print(f"  + {p}")

    if untracked_aur:
        ok = False
        print("Installed but not tracked in packages.yml (AUR):")
        for p in sorted(untracked_aur):
            print(f"  + {p}")

    if missing_pacman:
        ok = False
        print("Tracked in packages.yml but not installed (pacman):")
        for p in sorted(missing_pacman):
            print(f"  - {p}")

    if missing_aur:
        ok = False
        print("Tracked in packages.yml but not installed (AUR):")
        for p in sorted(missing_aur):
            print(f"  - {p}")

    if ok:
        print(f"OK — all installed packages tracked for {hostname}")

    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
