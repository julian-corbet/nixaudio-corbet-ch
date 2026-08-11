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
# which has two failure modes baked in: a host is silently absent until someone remembers to add it
# to a second, hand-maintained list, and a roaming laptop is simply dead once the LAN address stops
# resolving, with no fallback to the overlay. nixnet already solves exactly this — N candidate
# transports per peer, health-checked, hysteresis-damped, one winner published as a name. So peers
# here default to nixnet's peer set and are addressed BY NAME. Failover, roaming and "did anyone
# remember to add the new host to THIS list too" all stop being this module's problem.
#
# WHAT THAT DOES NOT BUY: this removes the SECOND list, not the possibility of a gap. Disproved in
# production (see the README's "not hypothetical" section): on the host that first adopted this
# module, one fleet machine was simply not a peer in nixnet's OWN table yet, so the fabric peer set
# derived from it inherited exactly the same gap, and that machine stayed unreachable. Deriving from
# one source doesn't make the source complete — it makes there be exactly ONE place to fix instead of
# N. That is a real, worthwhile improvement, and a narrower claim than "structurally impossible",
# which an earlier version of this comment and the README both said and which did not hold up. See
# the README's "What deriving from nixnet does and does not guarantee" for the full argument,
# including which half of "a host is missing" can and cannot be caught at eval time — the `warnings`
# entry below (`droppedPeers`) is the half that can.
{ lib, config, ... }:
let
  cfg = config.nixaudio.fabric;

  # Defensive read: nixnet is a soft dependency. Without it, peers must be given explicitly.
  nixnetPeers = config.nixnet.peers or { };

  # A peer nixnet has DECLARED (a key in nixnet.peers) but published no hostnames for at all is the
  # one flavour of "missing" this module can actually see -- unlike a host nixnet never learned about
  # in the first place, which is invisible from here (see this file's header, and the README's "What
  # deriving from nixnet does and does not guarantee"). Filtering it out of derivedPeers below is
  # correct -- there is nothing to dial -- but doing so with no trace would recreate the exact
  # "quietly missing" failure this module exists to remove, just one layer up. So it is named in a
  # warning (config.warnings, below) instead of dropped silently.
  droppedPeers = lib.attrNames (lib.filterAttrs (_: peer: peer.hostnames == [ ]) nixnetPeers);

  # A GENERAL defence against the failure class this option is the textbook example of (see the
  # `peers` option's own description, and README's incident writeup): `lib.mkDefault expectedPeers`
  # below is ONE definition of the whole attrset, so a consumer that writes a NESTED, dotted-path
  # definition -- `nixaudio.fabric.peers.<name>.host = "...";`, rather than the whole `peers =
  # {...}` -- sits at normal priority and wins the OPTION-level priority filter outright. That
  # discards `lib.mkDefault expectedPeers` in its entirety, not just the key the nested definition
  # touched: `attrsOf` only ever merges per-key among definitions that already survived that
  # filter. By the time `cfg.peers` is available here it is already the merged, final value.
  #
  # Compared against `expectedPeers` (post-`excludePeers`), NOT the raw `derivedPeers` -- a host
  # using `excludePeers` correctly ends up with `cfg.peers == expectedPeers` exactly (nothing to
  # warn about), while a host that instead reaches for a hand-written `peers = {...}` to drop a
  # name -- the shape `excludePeers` exists to replace -- still produces an effective set missing
  # something `expectedPeers` says should be there, so this still warns and still nudges toward the
  # declarative option instead. There is no way to tell "wrote a whole `peers = {...}` on purpose,
  # genuinely disjoint from the fleet" apart from "accidentally wrote a NESTED key and lost
  # siblings" from `cfg.peers` alone -- both can produce an effective set that is a subset of what
  # `expectedPeers` would supply. So this can only ever be a warning, not an assertion: an
  # acceptable false positive on the former (a comment that costs nothing to read past, and a
  # nudge toward `excludePeers` besides), against catching the latter for free.
  collapsedPeers =
    lib.optionals
      (cfg.peers != { } && cfg.peers != expectedPeers
        && lib.all (n: builtins.hasAttr n expectedPeers) (lib.attrNames cfg.peers))
      (lib.subtractLists (lib.attrNames cfg.peers) (lib.attrNames expectedPeers));

  # A peer is addressed by the first name nixnet publishes for it. nixnet maintains the
  # name -> currently-winning-address mapping, so this stays correct as transports flap.
  derivedPeers = lib.mapAttrs
    (_: peer: { host = builtins.head peer.hostnames; })
    (lib.filterAttrs (_: peer: peer.hostnames != [ ]) nixnetPeers);

  # The actual default: `derivedPeers`, minus any host named in `excludePeers`. Splitting this out
  # from `derivedPeers` itself keeps `droppedPeers` above comparing against the FULL nixnet-derived
  # set (an excluded peer was never "dropped" -- it was never wanted) while giving `excludePeers` a
  # declarative way to keep a permanent exclusion (a peer that genuinely should never join the
  # audio pool -- a service host running no PipeWire, say) LIVE against nixnet's table, rather than
  # needing a consumer to hand-copy `derivedPeers`' whole shape just to drop one name from it. See
  # the `excludePeers` option's own description for why this exists as a first-class mechanism
  # instead of leaving "exclude one peer" to a wholesale `peers = {...}` rewrite.
  expectedPeers = removeAttrs derivedPeers cfg.excludePeers;

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
        name — so adding a host to nixnet's peer table adds it to the audio pool automatically, with
        no second list to hand-maintain.

        That is a guarantee that this list matches nixnet's, not a guarantee that either one is
        complete: a host missing from `config.nixnet.peers` on this host — nixnet not composed there,
        or composed but that peer never actually joined nixnet's own view of the fleet — is derived as
        missing here too, with nothing in this module able to see the gap. One table to fix instead of
        two is the real benefit; it is not proof the fleet is whole. See the README's "What deriving
        from nixnet does and does not guarantee".

        A peer nixnet HAS declared but published zero hostnames for is a narrower, catchable case: it
        is dropped from this default and raises a `warnings` entry naming it, rather than disappearing
        with no trace.

        For a PERMANENT exclusion -- a peer that should never join the audio pool at all, a service
        host running no PipeWire, say -- prefer `excludePeers` instead of writing the rest of this
        attrset by hand: it keeps the derivation from `config.nixnet.peers` LIVE, so a future nixnet
        peer still joins the pool automatically, which setting `peers` wholesale here does not (a
        hand-typed attrset is a snapshot, not a subscription -- it has to be revisited by hand every
        time the fleet's peer table changes). Set `peers` explicitly only for a one-off override this
        host's own audio pool needs and `excludePeers` cannot express (an address nixnet does not
        know, say).
      '';
    };

    excludePeers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "mail-vps" ];
      description = ''
        Peer names to drop from the default `peers` derivation (`config.nixnet.peers`, filtered to
        published names) -- the declarative alternative to writing `peers` by hand just to exclude
        one name. Every OTHER nixnet peer, including one added after this host's config was last
        touched, still joins the audio pool automatically; only the names listed here are held back.

        This is deliberately a `listOf str`, not part of `peers` itself: `peers` stays a single
        attrset a consumer can still set wholesale when that is genuinely what is needed (see that
        option's own description), while a permanent exclusion is expressed as what it actually is
        -- a name, not a replacement value -- and composes with the live derivation instead of
        freezing it.
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

    mirrorPriority = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = ''
        `priority.session` stamped onto every mirrored peer device, so a MIRROR loses the
        default-sink race to real local hardware.

        This exists because of a live bug: WirePlumber's default-node picker selected a fabric
        mirror sink on one host, and a screen-streaming server — which has no explicit sink pin and
        simply follows the default — started streaming its audio into the mirror instead of out to
        the client.

        IT IS APPLIED WHERE THE TUNNEL IS CREATED, not from a WirePlumber rule, and the distinction
        is the difference between working and not. These mirrors are pulse tunnels loaded by
        pipewire-pulse; no WirePlumber MONITOR ever sees them, so no `monitor.*.rules` section can
        match them. The previous attempt used `stream.rules`, which governs streams rather than sink
        nodes, and therefore matched nothing at all — measured live, every mirror on the host
        carried no `priority.session` whatsoever. `../daemon/fabric-sync` now passes it in the
        module's own `sink_properties` / `source_properties`, where it lands.

        HONEST LIMIT, unchanged: this lowers priority, which settles the race wherever real hardware
        also exists. It does NOT make a mirror ineligible. On a host with no real output device the
        mirror is still the only candidate and will still be chosen; fixing that case needs an
        explicit sink pin in the consuming application, not a number here.

        Zero (the default) is the floor `nixaudio.priorities` refuses to let a local device tie with
        — see modules/devices.nix's number space.
      '';
    };
  };

  config = {
    nixaudio.fabric.peers = lib.mkDefault expectedPeers;

    nixaudio.fabric.pipewireConfig = lib.mkIf cfg.enable {
      "50-fabric-loops" = loopConfig;
    };

    nixaudio.fabric.pulseConfig = lib.mkIf cfg.enable {
      "50-fabric-listener" = listenerConfig;
    };

    # Non-fatal on purpose -- unlike the assertion below, this names a peer that WAS declared, just
    # incompletely, and a partially-configured nixnet peer is nixnet's business to finish, not a
    # reason to fail this host's whole audio config. See droppedPeers above and the README's "What
    # deriving from nixnet does and does not guarantee" for why this is the one flavour of "missing
    # peer" this module can actually detect.
    warnings = lib.optionals (cfg.enable && droppedPeers != [ ]) [
      ''
        nixaudio.fabric: nixnet declared peer(s) ${lib.concatStringsSep ", " droppedPeers} with no
        published hostnames, so they were dropped from nixaudio.fabric.peers instead of joining the
        audio pool. If that is unexpected, the gap is in nixnet's configuration, not this module's.
      ''
    ] ++ lib.optionals (cfg.enable && collapsedPeers != [ ]) [
      ''
        nixaudio.fabric.peers is missing ${lib.concatStringsSep ", " collapsedPeers}, which
        config.nixnet.peers can still derive right now and nixaudio.fabric.excludePeers does not
        name. If this host means to exclude ${lib.concatStringsSep ", " collapsedPeers} from the
        audio pool permanently, add it to nixaudio.fabric.excludePeers instead of a hand-written
        peers = { ... }; -- that stays correct as the fleet's peer table changes, this does not. If
        the exclusion was NOT intentional, this is likely the bug documented on the `peers` option
        itself: writing a NESTED key -- `nixaudio.fabric.peers.<name>.host = "...";` -- instead of
        the whole attrset sits at normal priority and silently discards the WHOLE `lib.mkDefault`
        derivation, not just the key it touched, which is exactly how one fleet host's audio peers
        previously collapsed to a single hand-written entry with no error at all.
      ''
    ];

    assertions = lib.optionals cfg.enable [
      {
        assertion = cfg.peers != { };
        message = ''
          nixaudio.fabric is enabled but has no peers.

          Peers default to config.nixnet.peers. If nixnet is not composed on this host, either add it
          (preferred — it brings LAN/overlay failover, so the fabric survives a roaming host) or set
          nixaudio.fabric.peers explicitly.

          This assertion only catches TOTAL loss (zero peers). A host missing from nixnet's OWN peer
          table is invisible to it -- see the README's "What deriving from nixnet does and does not
          guarantee".
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
