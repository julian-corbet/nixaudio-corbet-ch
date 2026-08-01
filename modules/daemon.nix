# nixaudio.fabric.daemon — the mirroring daemon, packaged and configured declaratively.
#
# WHAT CHANGED, AND WHAT DELIBERATELY DID NOT
#
# The daemon itself is the one previously hand-placed at ~/.local/bin/fabric-sync on each host. Its
# logic is load-bearing and proven in production — event-driven `pactl subscribe` per peer, a
# debounced reconciler with leading and trailing edges, a loop-guard that keeps a mirror from being
# re-mirrored, deterministic idempotent tunnel names, tunnel pinning to an isolated data loop, and a
# self-heal path for a wedged pulse. None of that was rewritten. Vendoring it here and rewriting it
# are two different changes, and mixing them would have made a regression impossible to attribute.
#
# What changed is only the CONFIG SURFACE: the hardcoded `FABRIC_NODES` IP table, `PORT` and
# `FABRIC_LOOP` now come from a generated JSON file. That is the difference between a daemon you
# edit on three machines and a daemon the fleet configures.
#
# WHY IT LIVES HERE NOW
#
# It previously lived in the infra repo and was copied onto each host by hand — which is exactly how
# one host ended up running a script no configuration described. One canonical copy, one
# generated config, one unit definition. The infra copy should be deleted in favour of this one
# rather than kept in parallel; two copies of a daemon are two daemons.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixaudio.fabric;

  # The daemon shells out to pactl (libpulse), ip (iproute2) and systemctl (its self-heal path).
  # Wrapping the PATH means it does not inherit whatever the invoking session happened to have,
  # which is the usual reason a user service behaves differently from an interactive test.
  runtimeDeps = [ pkgs.pulseaudio pkgs.iproute2 pkgs.systemd ];

  fabricSync = pkgs.runCommand "fabric-sync"
    {
      nativeBuildInputs = [ pkgs.makeWrapper ];
      meta.description = "Mirror every fabric peer's PipeWire devices as local tunnels";
    }
    ''
      mkdir -p $out/bin
      substitute ${../daemon/fabric-sync} $out/bin/fabric-sync \
        --replace-fail '#!/usr/bin/env python3' '#!${pkgs.python3}/bin/python3'
      chmod +x $out/bin/fabric-sync
      wrapProgram $out/bin/fabric-sync \
        --prefix PATH : ${lib.makeBinPath runtimeDeps}
    '';

  # The daemon's peer table is keyed by what it DIALS and valued by the display name that ends up in
  # the mirrored device's description. nixaudio.fabric.peers is the other way round (name -> host),
  # because that is the direction a human declares it, so invert here rather than making the
  # option surface awkward to write.
  peerTable = lib.listToAttrs (lib.mapAttrsToList
    (name: peer: lib.nameValuePair peer.host name)
    cfg.peers);

  fabricConfig = {
    port = cfg.listen.port;
    loop = cfg.loopName;
    peers = peerTable;
  };
in
{
  options.nixaudio.fabric.daemon = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      defaultText = lib.literalExpression "config.nixaudio.fabric.enable";
      description = ''
        Run the mirroring daemon on this host.

        Separate from `nixaudio.fabric.enable` because the two are genuinely separable: a host can
        publish its devices to the fabric (listener + config only) without itself mirroring anyone
        else's. A node with no local audio hardware that only needs to SEND audio elsewhere still
        wants the daemon; a node that only needs to be reachable does not.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = fabricSync;
      defaultText = lib.literalExpression "the vendored fabric-sync, wrapped with pactl/ip/systemctl on PATH";
      description = "Package providing `bin/fabric-sync`.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      example = "alice";
      description = ''
        The user whose PipeWire graph the daemon manages.

        This is a user service, not a system one, because the audio graph belongs to a user session —
        there is no system-wide PipeWire to attach to. On a headless node the user needs lingering
        enabled so its user manager (and therefore PipeWire and this daemon) starts at boot with no
        login session.
      '';
    };

    # Exposed as pure DATA rather than only as a built file. A generated file can only be inspected
    # by reading it back, which forces import-from-derivation -- so a test asserting on the config
    # would have to build it first, and could not run as a pure evaluation check at all.
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.unspecified;
      readOnly = true;
      default = fabricConfig;
      description = ''
        The daemon's effective configuration, as an attrset. `configFile` is this, serialised.

        Note the peer table here is keyed by what the daemon DIALS and valued by the display name
        that ends up in each mirrored device's description — inverted from `nixaudio.fabric.peers`,
        which is keyed by name because that is the direction a human declares it.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      internal = true;
      readOnly = true;
      default = (pkgs.formats.json { }).generate "nixaudio-fabric.json" cfg.daemon.settings;
      defaultText = lib.literalExpression "nixaudio.fabric.daemon.settings, serialised to JSON";
      description = "Generated daemon config, so both planes reference one derivation.";
    };
  };

  # No `config` section on purpose. This module defines the daemon's package and its effective
  # settings and stops there, so it can be imported into a home-manager module tree as readily as a
  # NixOS one -- home-manager has no `environment.etc`, and its systemd units use a different
  # (capitalised Unit/Service/Install) shape. Both projections live in their own plane files.
}
