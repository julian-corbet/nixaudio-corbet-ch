# home-manager plane — the Arch/CachyOS hosts.
#
# WHY THIS EXISTS SEPARATELY FROM THE SYSTEM PLANES
#
# Two of the three fleet nodes (a laptop and an Arch/CachyOS container, say) are not NixOS, and the
# audio graph on them is a USER-session concern: PipeWire runs as the logged-in user, its config
# lives under ~/.config, and the mirroring daemon is a `systemd --user` unit. nixarch's package
# reconciler is pacman/AUR convergence only — it has no file-placement or user-unit primitive — so it
# cannot put any of this in place. home-manager is the mechanism that can.
#
# This is exactly the gap that produced the original problem: the daemon and its PipeWire drop-ins
# were placed by hand on each Arch host, described by no configuration anywhere, and drifted. One
# host's copy still carried a comment claiming a firewall protected it that had since been replaced
# by a different mechanism entirely.
#
# WHAT IS SHARED AND WHAT IS NOT
#
# The pure modules (devices, fabric policy, daemon package + settings) are imported here UNCHANGED
# from ../modules. They define only `options.nixaudio.*` and pure derived values, with no reference
# to `environment.etc`, `services.pipewire`, or NixOS's systemd shape — which is what makes them
# importable into a home-manager tree at all. Only the projection below is plane-specific.
#
# Note home-manager's systemd units use the capitalised `Unit`/`Service`/`Install` shape rather than
# NixOS's flat `description`/`serviceConfig`/`wantedBy`. That difference is the reason this file
# exists rather than the NixOS projection being reused.
{ lib, config, ... }:
let
  cfg = config.nixaudio;

  # Under home-manager everything is user-scoped, so the daemon's config lives in the user's own
  # XDG config dir rather than /etc. The daemon reads NIXAUDIO_FABRIC_CONFIG, so nothing about it
  # needs to know which plane placed the file.
  configRelPath = "nixaudio/fabric.json";
  configAbsPath = "${config.xdg.configHome}/${configRelPath}";
in
{
  imports = [
    ../modules/devices.nix
    ../modules/fabric.nix
    ../modules/catalogue.nix
    ../modules/daemon.nix
  ];

  config = lib.mkIf cfg.fabric.enable {
    xdg.configFile = {
      # PipeWire and WirePlumber both read drop-ins from the user's XDG config dir, which take
      # precedence over the distro's own /usr/share defaults without modifying anything pacman owns.
      "pipewire/pipewire.conf.d/50-nixaudio-fabric-loops.conf".text =
        builtins.toJSON cfg.fabric.pipewireConfig."50-fabric-loops";

      "pipewire/pipewire-pulse.conf.d/50-nixaudio-fabric-listener.conf".text =
        builtins.toJSON cfg.fabric.pulseConfig."50-fabric-listener";

      "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf".text = cfg.namingConfig;
      "wireplumber/wireplumber.conf.d/52-nixaudio-fabric.conf".text = cfg.fabric.wireplumberConfig;
    }
    // lib.optionalAttrs cfg.fabric.daemon.enable {
      ${configRelPath}.source = cfg.fabric.daemon.configFile;
    };

    systemd.user.services = lib.mkIf cfg.fabric.daemon.enable {
      fabric-sync = {
        Unit = {
          Description = "Audio fabric device mirror (nixaudio)";
          # Wants rather than Requires: pipewire-pulse is socket-activated, and the daemon's own
          # self-heal path handles a pulse that disappears later. A hard Requires would drag the
          # daemon down with it and defeat that recovery.
          After = [ "pipewire-pulse.service" ];
          Wants = [ "pipewire-pulse.service" ];
        };

        Service = {
          Environment = [ "NIXAUDIO_FABRIC_CONFIG=${configAbsPath}" ];
          ExecStart = "${cfg.fabric.daemon.package}/bin/fabric-sync";
          Restart = "always";
          RestartSec = 5;
        };

        # default.target, not graphical-session.target: the daemon has no compositor dependency, and
        # a headless node with lingering enabled must still join the fabric with no session at all.
        Install.WantedBy = [ "default.target" ];
      };
    };
  };
}
