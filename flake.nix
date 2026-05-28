# iBP-Nix-Swap: NixOS desktop-environment swap flake
#
# Targets:
#   sudo ./scripts/swap.sh kde       # KDE Plasma 6 (default, persistent panels)
#   sudo ./scripts/swap.sh xfce      # XFCE 4 (clean tray, no SNI dropouts)
#   sudo ./scripts/swap.sh hypr      # Hyprland with monitor layout pre-wired
#   sudo ./scripts/swap.sh i3        # i3wm + polybar + rofi pre-wired
#   sudo ./scripts/swap.sh gnome | cinnamon | cosmic | lxqt | sway | cli
#
# IMPORTANT: hardware-configuration.nix and gpu.nix are NOT in this repo.
# They are emitted by `nixos-generate-config` on initial install. This flake
# imports them via relative paths from the repo root — drop them in beside
# flake.nix after install (or symlink from /etc/nixos/) and rebuild.

{
  description = "iBP-Nix-Swap — clean DE-swap flake for Todd's daily driver";

  inputs = {
    nixpkgs.url          = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, ... }@inputs:
  let
    system = "x86_64-linux";

    unstable = import nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };

    commonArgs = { inherit inputs unstable; };

    # hardware-configuration.nix + gpu.nix live next to this flake but are
    # NOT tracked in git. They come from `nixos-generate-config` + manual
    # gpu setup. If they're missing we skip them so `nix flake check`
    # still works in CI clones.
    hwModule  = if builtins.pathExists ./hardware-configuration.nix
                then [ ./hardware-configuration.nix ] else [];
    gpuModule = if builtins.pathExists ./gpu.nix
                then [ ./gpu.nix ] else [];

    sharedModules = [
      ./configuration.nix
      ./dev.nix
      ./tray-fix.nix
      ./persist.nix
      ./mounts.nix
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs       = true;
        home-manager.useUserPackages     = true;
        home-manager.extraSpecialArgs    = commonArgs;
        home-manager.users.todd          = import ./home.nix;
        home-manager.backupFileExtension = "backup";
      }
    ] ++ hwModule ++ gpuModule;

    mkSystem = deModule:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = commonArgs;
        modules     = sharedModules ++ (if deModule == null then [] else [ deModule ]);
      };
  in {
    nixosConfigurations = {
      kde       = mkSystem ./desktops/kde.nix;
      xfce      = mkSystem ./desktops/xfce.nix;
      hypr      = mkSystem ./desktops/hyprland.nix;
      i3        = mkSystem ./desktops/i3.nix;
      gnome     = mkSystem ./desktops/gnome.nix;
      cinnamon  = mkSystem ./desktops/cinnamon.nix;
      cosmic    = mkSystem ./desktops/cosmic.nix;
      lxqt      = mkSystem ./desktops/lxqt.nix;
      sway      = mkSystem ./desktops/sway.nix;
      "kde-hypr"= mkSystem ./desktops/kde-hypr.nix;
      cli       = mkSystem null;
    };
  };
}
