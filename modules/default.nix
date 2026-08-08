# The portable core: the device-naming layer, the fabric policy, the backend selection and the
# control selection. All four are pure functions of declared data, so they are identical on NixOS
# and on a system-manager host — only the projection onto the running system differs, and that lives
# in the per-plane files (./nixos.nix, ./backend-nixos.nix, ./controls-nixos.nix,
# ../system-manager/default.nix).
{ ... }:
{
  imports = [
    ./devices.nix
    ./fabric.nix
    ./catalogue.nix
    ./daemon.nix
    ./monitor.nix
    ./rt.nix
    ./backend.nix
    ./controls.nix
    ./nixos.nix
    ./backend-nixos.nix
    ./controls-nixos.nix
  ];
}
