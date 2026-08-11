# The portable core: the device-naming layer, the fabric policy and the backend selection. All
# three are pure functions of declared data, so they are identical on NixOS and on a system-manager
# host — only the projection onto the running system differs, and that lives in the per-plane files
# (./nixos.nix, ./backend-nixos.nix, ../system-manager/default.nix).
{ ... }:
{
  imports = [
    ./devices.nix
    ./dropins.nix
    ./fabric.nix
    ./catalogue.nix
    ./daemon.nix
    ./guard.nix
    ./monitor.nix
    ./rt.nix
    ./backend.nix
    ./nixos.nix
    ./backend-nixos.nix
  ];
}
