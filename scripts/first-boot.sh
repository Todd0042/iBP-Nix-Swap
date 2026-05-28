#!/usr/bin/env bash
# first-boot.sh — one-shot setup after a GUI (Calamares) NixOS install.
#
# This is the post-install counterpart to iBP-Nix-Install's bootstrap.sh.
# Instead of partitioning + nixos-install (which the graphical installer now
# does for you), this takes a freshly-installed-but-vanilla NixOS and turns it
# into the full daily-driver: your flake config, GPU + mounts wired up, and
# your logged-in app state cloned back in — exactly what the ISO installer
# laid down, minus the disk surgery.
#
# Run it from inside the cloned repo on the new system:
#   cd ~/Documents/GitHub/iBP-Nix-Swap
#   sudo ./scripts/first-boot.sh                 # interactive, KDE, seed from CachyOS
#   sudo ./scripts/first-boot.sh kde             # pick a DE
#   sudo ./scripts/first-boot.sh kde --gpu nvidia
#   sudo ./scripts/first-boot.sh kde --restore /run/media/usb/home-snapshot-*.tar.zst
#   sudo ./scripts/first-boot.sh kde --no-seed   # skip home cloning entirely
#
# PREREQS (the graphical installer step):
#   - Create the user **todd** with a password you'll remember. NixOS keeps
#     that password (mutableUsers defaults true), so the flake taking over
#     does NOT reset it.
#   - It doesn't matter which bootloader/DE you pick in Calamares — this flake
#     reconfigures the bootloader to GRUB+os-prober and installs your DE.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# -----------------------------------------------------------
# ARG PARSE
# -----------------------------------------------------------
TARGET_DE=""
GPU_PROFILE="auto"
RESTORE_SNAP=""
DO_SEED=1
AUTO=0
SISTER_GIT="https://github.com/Todd0042/iBP-Nix-Install.git"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu)      GPU_PROFILE="$2"; shift ;;
        --restore)  RESTORE_SNAP="$2"; shift ;;
        --no-seed)  DO_SEED=0 ;;
        --auto)     AUTO=1 ;;
        --help|-h)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        kde|xfce|hypr|i3|kde-hypr|gnome|cinnamon|cosmic|lxqt|sway|cli)
            TARGET_DE="$1" ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done

[ "$EUID" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }

# The unprivileged account whose ~/.persist + home we populate.
RUN_USER="${SUDO_USER:-todd}"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
RUN_HOME="${RUN_HOME:-/home/$RUN_USER}"
as_user() { sudo -u "$RUN_USER" "$@"; }

# Default DE.
if [ -z "$TARGET_DE" ]; then
    if [ "$AUTO" -eq 1 ]; then
        TARGET_DE="kde"
    else
        echo "Pick a desktop environment:"
        select OPT in kde xfce hypr i3 kde-hypr gnome cinnamon cosmic lxqt sway cli; do
            [ -n "$OPT" ] && TARGET_DE="$OPT" && break
        done
    fi
fi

echo "==============================================="
echo "  iBP-Nix-Swap first-boot setup"
echo "==============================================="
echo "  user         : $RUN_USER  ($RUN_HOME)"
echo "  desktop env  : $TARGET_DE"
echo "  gpu profile  : $GPU_PROFILE"
if [ -n "$RESTORE_SNAP" ]; then
    echo "  home source  : snapshot tarball ($RESTORE_SNAP)"
elif [ "$DO_SEED" -eq 1 ]; then
    echo "  home source  : seed from mounted ~/CachyOS"
else
    echo "  home source  : (skipped — fresh state)"
fi
echo ""
if [ "$AUTO" -eq 0 ]; then
    read -r -p "Proceed? (yes/NO): " ans
    [[ "$ans" =~ ^[Yy][Ee][Ss]$ ]] || { echo "Aborted."; exit 1; }
fi

# -----------------------------------------------------------
# 1. HARDWARE CONFIG — bring the installer's copy into the repo
# -----------------------------------------------------------
if [ ! -f "$REPO/hardware-configuration.nix" ]; then
    if [ -f /etc/nixos/hardware-configuration.nix ]; then
        echo "→ Copying /etc/nixos/hardware-configuration.nix into the repo"
        cp -f /etc/nixos/hardware-configuration.nix "$REPO/hardware-configuration.nix"
    else
        echo "→ No hardware-configuration.nix anywhere — generating one"
        nixos-generate-config --show-hardware-config > "$REPO/hardware-configuration.nix"
    fi
else
    echo "→ hardware-configuration.nix already present — keeping it"
fi

# -----------------------------------------------------------
# 2. GPU — scaffold gpu.nix if missing
# -----------------------------------------------------------
bash "$REPO/scripts/scaffold-gpu.sh" "$GPU_PROFILE"

# -----------------------------------------------------------
# 3. MOUNTS — fill Windows + CachyOS UUIDs in mounts.nix
# -----------------------------------------------------------
echo "→ Discovering Windows + CachyOS partitions"
bash "$REPO/scripts/discover-mounts.sh" || \
    echo "   ⚠ discover-mounts had trouble — review mounts.nix by hand."

# -----------------------------------------------------------
# 4 + 5. REBUILD + SEED HOME
# -----------------------------------------------------------
# persist.nix only wires an app's symlink once ~/.persist/<app> exists, so the
# order matters:
#   - snapshot restore doesn't need any mount → restore first, then ONE build.
#   - seeding from ~/CachyOS needs the automount live → build once to bring it
#     up, seed, then build again to wire the persist symlinks.
if [ -n "$RESTORE_SNAP" ]; then
    [ -f "$RESTORE_SNAP" ] || { echo "Snapshot not found: $RESTORE_SNAP"; exit 1; }
    echo "→ Restoring home snapshot into ~/.persist (before first rebuild)"
    as_user bash "$REPO/scripts/restore-home.sh" "$RESTORE_SNAP"
    echo "→ Rebuilding into $TARGET_DE (wires persist symlinks)"
    bash "$REPO/scripts/swap.sh" "$TARGET_DE"

elif [ "$DO_SEED" -eq 1 ]; then
    echo "→ Rebuilding into $TARGET_DE (brings up ~/CachyOS + ~/Windows mounts)"
    bash "$REPO/scripts/swap.sh" "$TARGET_DE"

    echo "→ Seeding ~/.persist from mounted CachyOS"
    if as_user test -d "$RUN_HOME/CachyOS/home/todd"; then
        as_user bash "$REPO/scripts/seed-from-cachyos.sh"
        echo "→ Rebuilding again to wire the freshly-seeded persist symlinks"
        bash "$REPO/scripts/swap.sh" "$TARGET_DE"
    else
        echo "   ⚠ ~/CachyOS/home/todd not reachable — skipping seed."
        echo "     Check mounts.nix UUIDs, then later run:"
        echo "       $REPO/scripts/seed-from-cachyos.sh && sudo $REPO/scripts/swap.sh $TARGET_DE"
    fi

else
    echo "→ Rebuilding into $TARGET_DE (no home seeding)"
    bash "$REPO/scripts/swap.sh" "$TARGET_DE"
fi

# -----------------------------------------------------------
# 6. SISTER REPO — clone iBP-Nix-Install alongside, like the ISO did
# -----------------------------------------------------------
GH_DIR="$RUN_HOME/Documents/GitHub"
if [ ! -d "$GH_DIR/iBP-Nix-Install" ]; then
    echo "→ Cloning sister repo iBP-Nix-Install into $GH_DIR"
    as_user mkdir -p "$GH_DIR"
    as_user git clone --depth 1 "$SISTER_GIT" "$GH_DIR/iBP-Nix-Install" || \
        echo "   ⚠ clone failed (offline?) — grab it later, it's optional."
fi

echo ""
echo "==============================================="
echo "  DONE — log out / back in to land in $TARGET_DE."
echo "  Your apps should already be logged in."
echo "  Swap DEs any time:  sudo $REPO/scripts/swap.sh <de>"
echo "==============================================="
