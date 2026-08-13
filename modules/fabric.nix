# nixaudio.fabric — one semantic PipeWire graph joined across hosts by upstream JackTrip.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixaudio.fabric;
  jacktrip = import ../jacktrip-package.nix { inherit pkgs; };
  audioPorts = map (peer: peer.audioPort) (lib.attrValues cfg.peers);
  duplicateAudioPorts = lib.length audioPorts != lib.length (lib.unique audioPorts);
  validMember = name: builtins.match "[a-z0-9][a-z0-9-]*" name != null;
  invalidPeers = builtins.filter (name: !(validMember name)) (lib.attrNames cfg.peers);
in
{
  options.nixaudio.fabric = {
    enable = lib.mkEnableOption "the cross-host PipeWire graph";

    node = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "studio";
      description = ''
        Stable member name inside the audio sharing circle. It is identity, not an address or an OS
        hostname: addresses may fail over while this name and persisted routes remain unchanged.
      '';
    };

    control = {
      listen = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        example = "192.0.2.10";
        description = ''
          Address on which nixaudiod publishes its semantic endpoint manifest. Peers exchange only
          stable endpoint identities and channel positions here; PipeWire object IDs never leave
          their host.

          The first implementation is deliberately a trusted-network protocol. It is not an
          authentication or encryption boundary; bind and firewall it accordingly.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 45900;
        description = "TCP port for the nixaudio peer-control protocol.";
      };
    };

    peers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          addresses = lib.mkOption {
            type = lib.types.nonEmptyListOf lib.types.str;
            example = [ "studio.lan" "studio.example.net" ];
            description = ''
              Ordered addresses for this peer. nixaudiod uses the first control endpoint that
              answers and starts the JackTrip client against the same address. This is explicit
              transport failover and has no dependency on an overlay product.
            '';
          };

          controlPort = lib.mkOption {
            type = lib.types.port;
            default = cfg.control.port;
            defaultText = lib.literalExpression "config.nixaudio.fabric.control.port";
            description = "The peer's nixaudio control port.";
          };

          audioPort = lib.mkOption {
            type = lib.types.port;
            example = 46001;
            description = ''
              UDP port dedicated to this unordered peer pair. Both ends declare the same value.
              A host gives each peer a distinct port, allowing one independently supervised
              multichannel JackTrip process per peer without one process per stream or device.
            '';
          };
        };
      });
      default = { };
      description = ''
        Members directly connected to this node. Circle discovery and pairing may populate this
        data later; the first implementation keeps membership explicit and transport-independent.
      '';
    };

    transport = {
      package = lib.mkOption {
        type = lib.types.package;
        default = jacktrip;
        defaultText = lib.literalExpression "the pinned upstream JackTrip release";
        description = "Upstream JackTrip package used for cross-host real-time media.";
      };

      command = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        internal = true;
        description = ''
          Plane-specific JackTrip command prefix. The NixOS projection uses its matching pw-jack;
          the system-manager/Home Manager projections use the foreign distribution's pw-jack.
        '';
      };

      sampleRate = lib.mkOption {
        type = lib.types.ints.positive;
        default = 48000;
        description = "JackTrip sample rate in Hz.";
      };

      period = lib.mkOption {
        type = lib.types.ints.positive;
        default = 128;
        description = "PipeWire/JACK period size in samples.";
      };

      bitResolution = lib.mkOption {
        type = lib.types.enum [ 8 16 24 32 ];
        default = 16;
        description = "JackTrip network sample resolution.";
      };

      queue = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 4;
        description = "JackTrip receive queue length in packets; JackTrip requires at least two.";
      };

      redundancy = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "JackTrip UDP packet redundancy factor.";
      };
    };
  };

  config.assertions = lib.optionals cfg.enable [
    {
      assertion = validMember cfg.node;
      message = "nixaudio.fabric.node must match [a-z0-9][a-z0-9-]*.";
    }
    {
      assertion = cfg.peers != { };
      message = "nixaudio.fabric is enabled but no peers are declared.";
    }
    {
      assertion = !(builtins.hasAttr cfg.node cfg.peers);
      message = "nixaudio.fabric.peers must not contain this node (${cfg.node}).";
    }
    {
      assertion = !duplicateAudioPorts;
      message = "nixaudio.fabric peers must use distinct audioPort values on this host.";
    }
    {
      assertion = invalidPeers == [ ];
      message = "nixaudio.fabric peer names must match [a-z0-9][a-z0-9-]*.";
    }
    {
      assertion = cfg.transport.command != [ ];
      message = "the active deployment plane did not provide nixaudio.fabric.transport.command.";
    }
    {
      assertion = cfg.transport.queue >= 2;
      message = "nixaudio.fabric.transport.queue must be at least two packets.";
    }
  ];
}
