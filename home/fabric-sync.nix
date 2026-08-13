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
  daemonConfigPath =
    if cfg.fabric.daemon.externalConfigPath == null
    then configAbsPath
    else cfg.fabric.daemon.externalConfigPath;
in
{
  imports = [
    ../modules/devices.nix
    ../modules/dropins.nix
    ../modules/fabric.nix
    ../modules/catalogue.nix
    ../modules/daemon.nix
    ../modules/guard.nix
  ];

  options.nixaudio.fabric.daemon.externalConfigPath = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "/etc/nixaudio/fabric.json";
    description = ''
      Existing daemon configuration to use instead of generating a second Home Manager copy.

      This is intended for an Arch host that composes the system-manager plane as the authority for
      host-level fabric facts and Home Manager only to run the user service. Leave it null when Home
      Manager is the only nixaudio plane; it will generate its own XDG configuration as before.
    '';
  };

  config = lib.mkMerge [
    # This plane writes the user's own XDG config, so on a host where it is the ONLY nixaudio plane
    # it must place the fragments. Where a system plane is composed too, that one should win and
    # this host has to say so -- once, in a file both trees import. ../modules/dropins.nix has the
    # failure that follows from both writing.
    { nixaudio.dropIns = lib.mkDefault "user"; }

    # ── The guard, and why it lives HERE on a non-NixOS host ─────────────────────────────────
    # It is a `systemd --user` unit, and this is the only plane on such a host with a real one.
    # system-manager can write /etc/systemd/user, but it never reloads the user manager, so a unit
    # it writes is inert until the next login -- a guard that arms itself after the next reboot is
    # not a guard. home-manager's sd-switch reloads and starts what it owns.
    #
    # No ConditionUser here, unlike the NixOS projection: a home-manager unit belongs to exactly one
    # user by construction, so the stray-root-instance hazard that option exists for cannot arise.
    (lib.mkIf cfg.guard.enable {
      xdg.configFile = lib.mkIf
        (cfg.dropIns == "user" && cfg.guard.wireplumberConfig != "")
        {
          "wireplumber/wireplumber.conf.d/50-nixaudio-reservation.conf".text =
            cfg.guard.wireplumberConfig;
        };

      systemd.user.services.nixaudio-alsa-guard = {
        Unit = {
          Description = "Repair a WirePlumber that came up with no ALSA devices (nixaudio)";
          After = [ "wireplumber.service" ];
          BindsTo = [ "wireplumber.service" ];
          PartOf = [ "wireplumber.service" ];
        };

        Service = {
          Type = "oneshot";
          ExecStart = "${cfg.guard.package}/bin/nixaudio-alsa-guard";
          TimeoutStartSec = cfg.guard.settleSeconds + 60;
          # Stopping wireplumber stops this (PartOf), and during a restart that arrives while the
          # guard is still in its settle poll -- which systemd records as a failure unless told
          # otherwise. See the NixOS projection for why a false failed state is worth one line.
          SuccessExitStatus = "SIGTERM";
        }
        // lib.optionalAttrs (cfg.guard.toolPath != [ ]) {
          # On a distro host the running PipeWire is the DISTRO's, so the client this script calls
          # must be too -- see nixaudio.guard.toolPath. This is the same anti-shadowing rule
          # ../lib/packages.nix applies to the daemons.
          Environment = [ "PATH=${lib.concatStringsSep ":" cfg.guard.toolPath}" ];
        };

        # WantedBy wireplumber, not default.target: the guard's whole subject is a wireplumber that
        # has just started, so it should run exactly when one does.
        Install.WantedBy = [ "wireplumber.service" ];
      };

      systemd.user.timers = lib.mkIf (cfg.guard.interval != null) {
        nixaudio-alsa-guard = {
          Unit.Description = "Periodic re-check for a WirePlumber with no ALSA devices (nixaudio)";
          Timer = {
            OnUnitActiveSec = cfg.guard.interval;
            OnStartupSec = cfg.guard.interval;
            RandomizedDelaySec = "30s";
          };
          Install.WantedBy = [ "timers.target" ];
        };
      };
    })

    (lib.mkIf cfg.fabric.enable {
      xdg.configFile =
        # The PipeWire/WirePlumber drop-ins, only when this plane owns them. Both read from the user's
        # XDG config dir, which takes precedence over the distro's own /usr/share defaults without
        # modifying anything pacman owns.
        lib.optionalAttrs (cfg.dropIns == "user") {
          "pipewire/pipewire.conf.d/50-nixaudio-fabric-loops.conf".text =
            builtins.toJSON cfg.fabric.pipewireConfig."50-fabric-loops";

          "pipewire/pipewire-pulse.conf.d/50-nixaudio-fabric-listener.conf".text =
            builtins.toJSON cfg.fabric.pulseConfig."50-fabric-listener";

          "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf".text = cfg.namingConfig;
        };
    })

    # The service is intentionally gated on daemon.enable rather than fabric.enable. With an
    # external config, Home Manager does not need to duplicate the host's listener or peer facts at
    # all; it owns only the user-service lifecycle while system-manager owns /etc.
    (lib.mkIf cfg.fabric.daemon.enable {
      xdg.configFile = lib.optionalAttrs (cfg.fabric.daemon.externalConfigPath == null) {
        ${configRelPath}.source = cfg.fabric.daemon.configFile;
      };

      systemd.user.services = {
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
            Environment = [ "NIXAUDIO_FABRIC_CONFIG=${daemonConfigPath}" ];
            ExecStart = "${cfg.fabric.daemon.package}/bin/fabric-sync";
            Restart = "always";
            RestartSec = 5;
          };

          # default.target, not graphical-session.target: the daemon has no compositor dependency, and
          # a headless node with lingering enabled must still join the fabric with no session at all.
          Install.WantedBy = [ "default.target" ];
        };
      };
    })
  ];
}
