# nixaudio.fabric — the many-to-many device pool.
#
# THE GOAL: every player on any host reaches every real output device on any host. Sources may be any
# node; sinks live wherever the hardware physically is. A device that moves between machines keeps
# its name, so a reference to it does not break when it is unplugged here and plugged in there.
#
# ── ROUTING INTENT IS STATE, NOT CONFIGURATION ──────────────────────────────────────────────────
#
# The obvious next option to add here is the wrong one: something like
# `nixaudio.fabric.routes.<stream> = "<sink>"`, pinning "this app's audio always goes to that sink".
# It is not here, and it should not be added later either, for the same reason
# `knowledge/hosts/shared/workstation-story.md` gives for why audio follows the WINDOW rather than
# the machine: "audio follows its windows around... I output where my ears are and all the inputs
# are added together." A pinned route is wrong the moment it is written, because the correct
# destination is a property of a LIVE session — which window got forwarded where, which peer is
# currently reachable, which sink the human is listening on right now — none of which exists yet at
# eval time and all of which can change without a rebuild. A Nix option can only ever describe the
# world as it was when `nixos-rebuild`/`home-manager switch` last ran; wiring "stream X → sink Y"
# into one would need a rebuild to move your own audio, and would already be stale the moment
# anyone plugs in a headset.
#
# This estate already drew exactly this line once: `nixiam`'s lldap module manages the identity
# SERVER and deliberately exposes no option for the users/groups/passwords living inside it, because
# — its own header — "the records living inside the directory are not configuration, they are
# data... treat the running database as live state you back up, never as something Nix should
# assert into existence." Routing intent is this module's version of that same directory: real,
# worth persisting, and NOT something a rebuild should own.
#
# What this module owns instead, and what each piece is for:
#   - the CATALOGUE  (catalogue.nix)   — stable NAMES a consumer can look up, never a binding.
#   - the TUNNELS     (this file, daemon.nix) — the pipes standing up, so routing has somewhere to go.
#   - PERMISSIONS     (listen.address, the shared cookie) — who may reach the graph at all.
#   - DEFAULT priorities (mirrorPriorityConfig, below) — a tie-breaker for an unopinionated app, not
#     a pin: Sunshine's default-sink race is settled here, but the moment an app (or a human, via
#     `wpctl`/`pw-link`) makes an explicit choice, that choice wins, exactly as it would for any
#     other PipeWire client.
#
# Everything else — which stream is actually connected to which sink, right now — is state that
# lives in the running PipeWire graph itself (`pw-link`, WirePlumber's session state, whatever a
# future tray writes there) and is read and written live, never rebuilt. Section 5 of the same design
# doc says the general form of this: "do not model less than the graph can express... declare into
# it, never re-describe it more poorly." A `routes` option would be exactly that poorer
# re-description — one static snapshot standing in for a thing that is, by design, always moving.
#
# ── WHY A DAEMON AND NOT A STANDARD ─────────────────────────────────────────────────────────────
#
# This was re-examined properly rather than inherited. AES67 (the open interop layer under
# SMPTE ST 2110-30) is the professional answer and PipeWire implements it natively — but it assumes
# PTP clock sync and multicast on a managed LAN, so it does not traverse a routed overlay and does
# not survive a roaming laptop. ROC (module-roc-sink/source) tolerates lossy links but is explicitly
# point-to-point with NO discovery. zeroconf-discover is mDNS/LAN-only, needs a manual per-sink
# publish, and has a standing bug that filters sources (microphones) out entirely. Snapcast is
# one-to-many broadcast, the wrong shape.
#
# So the transport primitives are standard and already present; what is missing upstream is the
# POLICY that maps "every device, every direction, over whichever path is currently up". That policy
# is the daemon. It stays — but it stops carrying things its siblings already own.
#
# ── WHAT THIS MODULE REFUSES TO REINVENT ────────────────────────────────────────────────────────
#
# Peer addressing is nixnet's. The daemon previously carried a hardcoded LAN-IP table:
#
#     FABRIC_NODES = { "198.51.100.10": "host-b", "198.51.100.14": "host-c" }
#
# which has two failure modes baked in: a host is silently absent until someone remembers to add it,
# and a roaming laptop is simply dead once the LAN address stops resolving, with no fallback to the
# overlay. nixnet already solves exactly this — N candidate transports per peer, health-checked,
# hysteresis-damped, one winner published as a name. So peers here default to nixnet's peer set and
# are addressed BY NAME. Failover, roaming and "did anyone add the new host" all stop being this
# module's problem.
{ lib, config, ... }:
let
  cfg = config.nixaudio.fabric;

  # Defensive read: nixnet is a soft dependency. Without it, peers must be given explicitly.
  nixnetPeers = config.nixnet.peers or { };

  # A peer is addressed by the first name nixnet publishes for it. nixnet maintains the
  # name -> currently-winning-address mapping, so this stays correct as transports flap.
  derivedPeers = lib.mapAttrs
    (_: peer: { host = builtins.head peer.hostnames; })
    (lib.filterAttrs (_: peer: peer.hostnames != [ ]) nixnetPeers);

  listenAddress =
    if cfg.listen.address == "any" then "0.0.0.0" else cfg.listen.address;

  listenerConfig = {
    "pulse.cmd" = [
      {
        cmd = "load-module";
        args = "module-native-protocol-tcp listen=${listenAddress} port=${toString cfg.listen.port}"
          # auth-anonymous is set for form only. It does NOT authenticate: verified live on
          # PipeWire 1.6.8 that a wrong or empty cookie still gets full read access to device
          # topology, the client list and the whole module config. The gate is the bind address
          # and the firewall, never this flag.
          + " auth-anonymous=0";
      }
    ];
  };

  # Give fabric tunnels their own data loop. A stalled remote tunnel then wedges only this loop,
  # leaving data-loop.0 -- where the real hardware sinks and local apps are scheduled -- untouched.
  loopConfig = {
    "context.properties" = {
      "context.num-data-loops" = 2;
      "context.data-loops" = [
        {
          "loop.class" = [ "data.rt" "audio.rt" ];
          "thread.name" = "data-loop.0";
        }
        {
          "loop.class" = [ "fabric.rt" ];
          "thread.name" = cfg.loopName;
        }
      ];
    };
  };

  # Mirrored peer devices must lose the default-sink race against real local hardware.
  #
  # This exists because of a live bug: WirePlumber's default-node picker selected a fabric mirror
  # sink on the desktop, and Sunshine -- which has no explicit sink pin and simply follows the
  # default -- started streaming its audio into the mirror instead of out to Moonlight.
  #
  # HONEST LIMIT: this lowers priority, which settles the race wherever real hardware also exists.
  # It does NOT make a mirror ineligible. On a host with NO real output device (a system-manager
  # host with no local audio hardware, for instance) the mirror is still the only candidate and will
  # still be chosen. Fixing that case needs an explicit sink pin in the consuming application, not a
  # priority tweak here.
  mirrorPriorityConfig = ''
    # Generated by nixaudio.fabric -- do not edit.
    monitor.alsa.rules = [ ]

    stream.rules = [
      {
        matches = [
          { node.name = "~${cfg.mirrorPrefix}.*" }
        ]
        actions = {
          update-props = {
            priority.session = 0
            priority.driver = 0
          }
        }
      }
    ]
  '';
in
{
  options.nixaudio.fabric = {
    enable = lib.mkEnableOption "the cross-host audio device pool";

    listen = {
      address = lib.mkOption {
        type = lib.types.str;
        example = "203.0.113.14";
        description = ''
          Address the PipeWire pulse TCP listener binds to.

          There is deliberately NO default. The pulse protocol has no working authentication on
          PipeWire 1.6.x — verified live, a wrong or empty cookie still gets full read of device
          topology and the module config — so whoever can reach this socket can enumerate every
          device and record from any of them, including a room microphone. The bind address is a
          real part of the security boundary and must be chosen deliberately, not inherited.

          Give the host's overlay address to confine the listener to the mesh. `"any"` binds
          0.0.0.0 and is only defensible behind a firewall you have actually verified — note that
          an interface-scoped rule authorizes every peer on that interface, not just fabric members.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 4713;
        description = ''
          TCP port for the pulse listener. 4713 is the pulse default and is what existing consumers
          expect — `nixremote` matches sink descriptions of the form
          `Tunnel to tcp:<addr>:4713/<device>`, so changing this needs that side updated too.
        '';
      };
    };

    peers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.host = lib.mkOption {
          type = lib.types.str;
          description = ''
            Name or address to reach this peer's listener on. Prefer a NAME that nixnet publishes:
            nixnet keeps it pointed at whichever transport is currently healthy, so the fabric
            follows a roaming host between LAN and overlay without this module knowing anything
            about transports.
          '';
        };
      });
      defaultText = lib.literalExpression "derived from config.nixnet.peers";
      description = ''
        The fabric's peers. Defaults to every peer nixnet declares, addressed by nixnet's published
        name — so adding a host to the fleet adds it to the audio pool, with no second list to keep
        in sync and no way for a host to be silently missing from one of them.

        Set explicitly only to make the audio pool a strict subset of the fleet.
      '';
    };

    mirrorPrefix = lib.mkOption {
      type = lib.types.str;
      default = "fabric_";
      description = ''
        Node-name prefix identifying a mirrored peer device. Used both as the daemon's loop-guard
        (never mirror a mirror) and to deprioritise mirrors in default-sink selection.
      '';
    };

    loopName = lib.mkOption {
      type = lib.types.str;
      default = "fabric-loop.0";
      description = "Thread name of the dedicated data loop that fabric tunnels are pinned to.";
    };

    pipewireConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.unspecified;
      internal = true;
      readOnly = true;
      description = "Generated pipewire config fragments, consumed by whichever plane is in use.";
    };

    pulseConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.unspecified;
      internal = true;
      readOnly = true;
      description = "Generated pipewire-pulse config fragments.";
    };

    wireplumberConfig = lib.mkOption {
      type = lib.types.lines;
      internal = true;
      readOnly = true;
      description = "Generated WirePlumber rules for mirror deprioritisation.";
    };
  };

  config = {
    nixaudio.fabric.peers = lib.mkDefault derivedPeers;

    nixaudio.fabric.pipewireConfig = lib.mkIf cfg.enable {
      "50-fabric-loops" = loopConfig;
    };

    nixaudio.fabric.pulseConfig = lib.mkIf cfg.enable {
      "50-fabric-listener" = listenerConfig;
    };

    nixaudio.fabric.wireplumberConfig = lib.mkIf cfg.enable mirrorPriorityConfig;

    assertions = lib.optionals cfg.enable [
      {
        assertion = cfg.peers != { };
        message = ''
          nixaudio.fabric is enabled but has no peers.

          Peers default to config.nixnet.peers. If nixnet is not composed on this host, either add it
          (preferred — it brings LAN/overlay failover, so the fabric survives a roaming host) or set
          nixaudio.fabric.peers explicitly.
        '';
      }
      {
        # The listener is the one thing here that is remotely reachable and unauthenticated. A host
        # binding it wide open should have said so out loud.
        assertion = cfg.listen.address != "";
        message = ''
          nixaudio.fabric.listen.address is empty. Set it to this host's overlay address to confine
          the listener to the mesh, or to "any" if you have verified a firewall in front of it.
        '';
      }
    ];
  };
}
