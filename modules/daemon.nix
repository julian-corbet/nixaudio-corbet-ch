# nixaudiod is the single runtime owner of the live PipeWire graph. Nix owns its executable,
# declared device/peer vocabulary and service lifecycle; remembered routes remain user state.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixaudio;
  package = import ../package.nix { inherit pkgs; };
  daemonConfig = {
    node = cfg.fabric.node;
    control = cfg.fabric.control;
    transport = {
      command = cfg.fabric.transport.command;
      sampleRate = cfg.fabric.transport.sampleRate;
      period = cfg.fabric.transport.period;
      bitResolution = cfg.fabric.transport.bitResolution;
      queue = cfg.fabric.transport.queue;
      redundancy = cfg.fabric.transport.redundancy;
    };
    peers = lib.mapAttrs
      (_: peer: {
        inherit (peer) addresses controlPort audioPort;
        # Only the overrides this peer actually set. An absent field means "take the host default";
        # emitting nulls would make the daemon's Option<T> read them as deliberate.
        transport = lib.filterAttrs (_: value: value != null) peer.transport;
      })
      cfg.fabric.peers;
    catalogue = cfg.fabric.catalogue;
  };
in
{
  options.nixaudio = {
    daemon = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.fabric.enable;
        defaultText = lib.literalExpression "config.nixaudio.fabric.enable";
        description = "Run nixaudiod, the sole owner of live graph observation, routing and fabric reconciliation.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = package;
        defaultText = lib.literalExpression "the nixaudio Rust package from this flake";
        description = "Package providing nixaudiod, nixaudioctl and nixaudio-tray.";
      };
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        example = "alice";
        description = "NixOS user whose session PipeWire graph the nixaudio user services own.";
      };
      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.unspecified;
        readOnly = true;
        default = daemonConfig;
        description = "Effective nixaudiod configuration as pure data.";
      };
      configFile = lib.mkOption {
        type = lib.types.path;
        internal = true;
        readOnly = true;
        default = (pkgs.formats.json { }).generate "nixaudio.json" cfg.daemon.settings;
        description = "Serialised nixaudiod configuration.";
      };
    };

    tray = {
      enable = lib.mkEnableOption "the nixaudio StatusNotifier tray frontend";
      package = lib.mkOption {
        type = lib.types.package;
        default = cfg.daemon.package;
        defaultText = lib.literalExpression "config.nixaudio.daemon.package";
        description = "Package providing nixaudio-tray.";
      };
    };
  };

  config.assertions = lib.optional cfg.fabric.enable {
    assertion = cfg.daemon.enable;
    message = ''
      nixaudio.fabric.enable requires nixaudio.daemon.enable. The daemon is the runtime owner of
      peer discovery, JackTrip supervision and graph routing; a fabric without it renders static
      configuration but never joins the declared peers.
    '';
  };
}
