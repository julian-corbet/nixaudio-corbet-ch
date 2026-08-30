# The NixOS backend for `nixaudio.want`.
#
# NixAudio may own this backend because nixpkgs is already its package universe. The foreign-system
# backend does not live here: mapping the same roles to pacman/AUR names and `/usr` paths is Arch
# platform knowledge, so nixarch owns that projection.
{ lib, config, pkgs, ... }:
let
  want = config.nixaudio.want or { };
  roles = import ../lib/nixos-roles.nix { inherit lib pkgs; };
  protocols = want.clientProtocols or [ ];
in
{
  config = lib.mkIf (want != { }) {
    assertions = [
      {
        assertion = roles.supports want;
        message = ''
          nixaudio NixOS backend does not resolve every role in `nixaudio.want`.
          Update lib/nixos-roles.nix and the projection together.
        '';
      }
    ];

    services.pipewire = {
      enable = want.graph == "pipewire";
      wireplumber.enable = want.sessionPolicy == "wireplumber";

      # These are application compatibility protocols inside the local graph, never the network
      # transport. Each is projected through the real NixOS option that supplies its config and
      # units; installing another PipeWire derivation would shadow the one those options own.
      alsa.enable = lib.mkDefault (lib.elem "alsa" protocols);
      jack.enable = lib.elem "jack" protocols;
      pulse.enable = lib.elem "pulse" protocols;
    };

    environment.systemPackages = roles.packagesFor want;

    # Firmware is a kernel search-path input, not a program on PATH.
    hardware.firmware = roles.firmwareFor want;
  };
}
