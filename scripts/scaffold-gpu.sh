#!/usr/bin/env bash
# scaffold-gpu.sh — write a gpu.nix into the repo root if one isn't there yet.
#
# gpu.nix is intentionally untracked (per-machine, see .gitignore + README).
# The ISO installer used to scaffold it inside install-core.sh; this is the
# standalone equivalent for the GUI-installer path.
#
# Usage:
#   ./scripts/scaffold-gpu.sh            # auto-detect from lspci (default)
#   ./scripts/scaffold-gpu.sh nvidia     # force a profile: nvidia|amd|intel
#   ./scripts/scaffold-gpu.sh --force    # overwrite an existing gpu.nix
#
# Idempotent: refuses to clobber an existing gpu.nix unless --force is passed.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPU_NIX="$REPO/gpu.nix"

FORCE=0
PROFILE=""
for arg in "$@"; do
    case "$arg" in
        --force)            FORCE=1 ;;
        nvidia|amd|intel)   PROFILE="$arg" ;;
        auto)               PROFILE="" ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

if [ -f "$GPU_NIX" ] && [ "$FORCE" -eq 0 ]; then
    echo "→ gpu.nix already exists — leaving it alone (pass --force to overwrite)."
    exit 0
fi

# Auto-detect if no profile was forced.
if [ -z "$PROFILE" ]; then
    GPU_RAW=$(lspci 2>/dev/null | grep -Ei "VGA|3D|Display" || true)
    echo "GPU(s):"
    echo "$GPU_RAW" | sed 's/^/  /'
    if   echo "$GPU_RAW" | grep -qi nvidia; then PROFILE="nvidia"
    elif echo "$GPU_RAW" | grep -qi amd;    then PROFILE="amd"
    else PROFILE="intel"
    fi
fi
echo "→ Scaffolding gpu.nix for profile: $PROFILE"

case "$PROFILE" in
    nvidia)
        cat > "$GPU_NIX" <<'EOF'
# gpu.nix — NVIDIA desktop (single dGPU; NO Intel iGPU on i7-14700F)
{ config, pkgs, ... }:
{
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    package             = config.boot.kernelPackages.nvidiaPackages.latest;
    modesetting.enable  = true;
    powerManagement.enable      = true;
    powerManagement.finegrained = false;
    open                = true;           # open kernel module (Turing+)
    nvidiaSettings      = true;
  };

  # No `hardware.nvidia.prime` block — there is no iGPU to offload to.
}
EOF
        ;;
    amd)
        cat > "$GPU_NIX" <<'EOF'
{ config, pkgs, ... }:
{
  services.xserver.videoDrivers = [ "amdgpu" ];
  hardware.amdgpu.opencl.enable = true;
}
EOF
        ;;
    intel)
        cat > "$GPU_NIX" <<'EOF'
{ config, pkgs, ... }:
{
  services.xserver.videoDrivers = [ "modesetting" ];
}
EOF
        ;;
esac

echo "→ Wrote $GPU_NIX"
