# nixaudio.backend — the semantic requirements of the local audio graph.
#
# This module publishes WHAT an enabled NixAudio host needs through the read-only
# `nixaudio.want` contract. It deliberately knows no package name, nixpkgs attribute or binary
# path. Platform backends resolve the contract:
#
#   - backend-nixos.nix, in this repository, projects it through NixOS options and nixpkgs;
#   - nixarch's audio backend projects it through pacman/AUR and supplies the foreign-system
#     command paths.
#
# That is the same boundary as nixdesktop.want: in-domain provider choices stay here, while the
# cross-domain spelling of those choices belongs to the hub that owns the platform.
{ lib, config, ... }:
let
  cfg = config.nixaudio.backend;
in
{
  options = {
    nixaudio.backend = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.nixaudio.fabric.enable;
        defaultText = lib.literalExpression "config.nixaudio.fabric.enable";
        description = ''
          Whether this host needs the local audio graph NixAudio integrates with.

          Defaults to `nixaudio.fabric.enable`, because the fabric routes through PipeWire and
          carries its media through the graph's JACK client protocol. Enabling it without the
          fabric is a supported local-only audio configuration.

          This option installs nothing by itself. It publishes `nixaudio.want`; the active
          platform backend resolves those semantic requirements.
        '';
      };

      sofFirmware.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Require Intel Sound Open Firmware for this host's built-in DSP.

          Default OFF and deliberately not derived: evaluation cannot see the hardware of the
          machine it is configuring. USB audio devices do not imply this requirement, and a
          container cannot load firmware into the kernel it shares with its host.
        '';
      };
    };

    # No default: readOnly permits one definition, and the disabled case is represented by the
    # empty value rather than by withholding that definition.
    nixaudio.want = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      description = ''
        READ-ONLY, computed. The complete semantic contract a platform backend consumes.

        Provider and protocol names describe audio roles, not packages: the same `pipewire`
        graph is a set of NixOS service options on one plane and several pacman packages on a
        foreign-system plane. A backend that reads only this attrset needs no knowledge of the
        options that produced it, and this module needs no knowledge of platform package naming.
      '';
    };
  };

  config = {
    nixaudio.want = lib.optionalAttrs cfg.enable {
      graph = "pipewire";
      sessionPolicy = "wireplumber";
      clientProtocols = [ "alsa" "jack" "pulse" ];
      diagnostics = [ "alsa" ];
      firmware = lib.optional cfg.sofFirmware.enable "intel-sof";
    };

    assertions = [
      {
        assertion = config.nixaudio.fabric.enable -> cfg.enable;
        message = ''
          nixaudio: `fabric.enable` requires the local audio backend and its JACK client protocol.
        '';
      }
    ];
  };
}
