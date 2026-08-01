# The portable core: the device-naming layer and the fabric policy. Both are pure functions of
# declared data, so they are identical on NixOS and on a system-manager host — only the projection
# onto the running system differs, and that lives in the per-plane files.
{ ... }:
{
  imports = [
    ./devices.nix
    ./fabric.nix
    ./catalogue.nix
    ./daemon.nix
    ./monitor.nix
    ./rt.nix
    ./nixos.nix
  ];
}
