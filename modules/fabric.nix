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
        default = 26300;
        description = ''
          TCP port for the nixaudio peer-control protocol.

          Deliberately below the kernel's default ephemeral floor of 32768. A port inside that range
          is one the kernel may hand to any process that asks for "any port"; if it does so before
          this daemon binds, the host silently drops out of its circle.
        '';
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
            example = 26301;
            description = ''
              UDP port dedicated to this unordered peer pair. Both ends declare the same value.
              A host gives each peer a distinct port, allowing one independently supervised
              multichannel JackTrip process per peer without one process per stream or device.
            '';
          };

          transport = lib.mkOption {
            type = lib.types.submodule {
              options = {
                period = lib.mkOption {
                  type = lib.types.nullOr lib.types.ints.positive;
                  default = null;
                  description = "Override this link's period, in samples.";
                };
                bitResolution = lib.mkOption {
                  type = lib.types.nullOr (lib.types.enum [ 8 16 24 32 ]);
                  default = null;
                  description = "Override this link's network sample resolution.";
                };
                queue = lib.mkOption {
                  type = lib.types.nullOr (lib.types.strMatching "auto|auto[0-9]+|[0-9]+");
                  default = null;
                  description = "Override this link's `-q`. Same spelling as the host-wide option.";
                };
                redundancy = lib.mkOption {
                  type = lib.types.nullOr lib.types.ints.positive;
                  default = null;
                  description = "Override this link's UDP packet redundancy factor.";
                };
              };
            };
            default = { };
            description = ''
              Per-link overrides of the host-wide `transport` defaults. `null` means "take the
              default", never "zero".

              These four are properties of a LINK, not of this host: there is exactly one JackTrip
              process per peer pair, so a value that suits a peer on the same switch is the wrong
              value for one on a hotspot, and a circle has both at once. Only `command` and
              `sampleRate` stay host-wide, because PipeWire runs one graph at one clock and there is
              physically only one of each to have.
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
          Plane-specific JackTrip command prefix. Every plane uses nixpkgs' own pw-jack, matched
          to the Nix-built JackTrip it redirects -- including on a foreign distribution, where the
          sound server is the distro's but the JACK shim cannot be. See system-manager/default.nix
          for why that boundary falls where it does.
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
        type = lib.types.strMatching "auto|auto[0-9]+|[0-9]+";
        default = "auto";
        example = "auto20";
        description = ''
          JackTrip's `-q`, as JackTrip spells it.

          `"auto"` lets the Regulator choose the headroom and keep re-choosing it from the link it
          is actually on, floored at one period. That is the default because it is the only setting
          that spends the least latency a path allows instead of a constant chosen for some other
          path -- and in a circle of a dozen members, some peer is always on a worse link than the
          one a constant was picked for. `"auto<N>"` seeds that adaptation with N milliseconds.

          A bare number is a FIXED tolerance in MILLISECONDS with adaptation switched off -- not a
          count of packets, whatever this option used to say. Under `--bufstrategy 3`, which is the
          only strategy nixaudio emits, upstream reads it that way: "mBufferQueueLength is in
          integer msec not packets". The old `4` therefore bought four milliseconds, less than two
          128-frame periods at 48 kHz, and could not absorb a single late packet.
        '';
      };

      redundancy = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "JackTrip UDP packet redundancy factor.";
      };
    };
  };

  # A port at or above the ephemeral floor is one the kernel may already have handed to something
  # else by the time we bind. JackTrip then exits, that pair carries no audio, and nothing in the
  # audio graph explains it. A warning rather than an assertion: an operator may legitimately have
  # narrowed the range, and /proc/sys/net/ipv4/ip_local_port_range is the only place that knows.
  config.warnings =
    let
      ephemeralFloor = 32768;
      offenders =
        lib.optional (cfg.control.port >= ephemeralFloor)
          "control.port ${toString cfg.control.port}"
        ++ lib.mapAttrsToList (name: peer: "peers.${name}.audioPort ${toString peer.audioPort}")
          (lib.filterAttrs (_: peer: peer.audioPort >= ephemeralFloor) cfg.peers);
    in
    lib.optionals cfg.enable (lib.optional (offenders != [ ]) ''
      nixaudio.fabric: ${lib.concatStringsSep ", " offenders} at or above 32768, the usual
      ephemeral-port floor. The kernel may hand such a port to any process asking for "any port"
      before this host binds it; the bind then fails and that pair carries no audio. Choose ports
      below the floor, or narrow net.ipv4.ip_local_port_range on every host in the circle.
    '');

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
  ] ++ lib.optionals cfg.enable (
    # A fixed tolerance below two period durations cannot absorb one late packet, so it guarantees
    # the glitching it was meant to prevent. Adaptive spellings are exempt: the Regulator floors its
    # own headroom at a period. Checked per link, because `period` is now a per-link property.
    let
      fixedMs = queue: if builtins.match "[0-9]+" queue != null then lib.toInt queue else null;
      autoHeadroomMs = queue:
        let match = builtins.match "auto([0-9]+)" queue;
        in if match == null then null else lib.toInt (builtins.head match);
      floorMs = period: (2000 * period + cfg.transport.sampleRate - 1) / cfg.transport.sampleRate;
      links = [{ name = "transport"; inherit (cfg.transport) queue period; }]
        ++ lib.mapAttrsToList
          (name: peer: {
            name = "peers.${name}.transport";
            queue = if peer.transport.queue != null then peer.transport.queue else cfg.transport.queue;
            period = if peer.transport.period != null then peer.transport.period else cfg.transport.period;
          })
          cfg.peers;
    in
    lib.concatMap
      (link: [
        {
          assertion = let ms = fixedMs link.queue; in ms == null || ms >= floorMs link.period;
          message = ''
            nixaudio.fabric.${link.name}.queue is ${link.queue} ms of FIXED jitter tolerance, below
            the ${toString (floorMs link.period)} ms that two periods of ${toString link.period}
            frames at ${toString cfg.transport.sampleRate} Hz occupy. Under bufstrategy 3 that number
            is milliseconds, not packets, and adaptation is off. Use "auto" unless you have measured
            this link.
          '';
        }
        {
          assertion = let ms = autoHeadroomMs link.queue; in ms == null || ms <= 250;
          message = ''
            nixaudio.fabric.${link.name}.queue is "${link.queue}", which seeds
            ${toString (autoHeadroomMs link.queue)} ms of adaptive headroom, past JackTrip's 250 ms
            cap. Use "auto" to let the Regulator choose its own initial value, or choose an auto<N>
            seed no greater than 250.
          '';
        }
      ])
      links
  );
}
