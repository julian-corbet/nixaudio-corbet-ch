# NixOS plane: project the generated config through services.pipewire, the idiomatic path here.
{ lib, config, ... }:
let
  cfg = config.nixaudio;
in
{
  config = lib.mkIf cfg.fabric.enable {
    services.pipewire = {
      enable = lib.mkDefault true;
      alsa.enable = lib.mkDefault true;
      # pipewire-pulse is not optional for this module: it hosts the listener peers connect to and
      # is what `pactl` (and therefore the mirroring daemon) talks to.
      pulse.enable = true;

      extraConfig.pipewire = cfg.fabric.pipewireConfig;
      extraConfig.pipewire-pulse = cfg.fabric.pulseConfig;
    };

    # WirePlumber rules go through /etc rather than services.pipewire.wireplumber.configPackages so
    # that the exact same rendered text is used on both planes -- a system-manager host has no
    # configPackages equivalent, and one rendering is easier to reason about than two.
    environment.etc = {
      "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf".text = cfg.namingConfig;
      "wireplumber/wireplumber.conf.d/52-nixaudio-fabric.conf".text = cfg.fabric.wireplumberConfig;
    }
    // lib.optionalAttrs cfg.fabric.daemon.enable {
      "nixaudio/fabric.json".source = cfg.fabric.daemon.configFile;
    };

    systemd.user.services = lib.mkIf cfg.fabric.daemon.enable {
      fabric-sync = {
        description = "Audio fabric device mirror (nixaudio)";
        # Wants, not Requires: pipewire-pulse is socket-activated, and the daemon's own self-heal
        # handles a pulse that goes away later. A hard Requires would take the daemon down with it.
        after = [ "pipewire-pulse.service" ];
        wants = [ "pipewire-pulse.service" ];
        wantedBy = [ "default.target" ];

        environment.NIXAUDIO_FABRIC_CONFIG = "/etc/nixaudio/fabric.json";

        serviceConfig = {
          ExecStart = "${cfg.fabric.daemon.package}/bin/fabric-sync";
          Restart = "always";
          RestartSec = 5;
        };
      };
    };
  };
}
