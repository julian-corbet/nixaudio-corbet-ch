# NixOS plane: project the generated config through services.pipewire, the idiomatic path here.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixaudio;
in
{
  config = lib.mkMerge [
    # `dropIns` defaults to "system" here: this plane can write /etc, which every session on the
    # host reads, so a NixOS host that ALSO runs home-manager should let the system copy be the only
    # one. See ./dropins.nix for what happens when both write.
    { nixaudio.dropIns = lib.mkDefault "system"; }

    {
      assertions = lib.optional cfg.daemon.enable {
        assertion = cfg.daemon.user != null;
        message = ''
          nixaudio.daemon.user must name the NixOS user whose PipeWire graph nixaudiod
          manages when the daemon is enabled.
        '';
      };
    }

    # NixOS installs user units into every user's manager. State the intended owner once and use it
    # for all three mechanisms that make a headless audio session reliable: device access, lingering
    # and ConditionUser fences on both nixaudiod and the ALSA guard.
    (lib.mkIf
      (cfg.daemon.enable && cfg.daemon.user != null)
      {
        users.users.${cfg.daemon.user} = {
          extraGroups = [ "audio" ];
          linger = true;
        };
        nixaudio.guard.user = lib.mkDefault cfg.daemon.user;
      })

    # ── The guard is gated on ITSELF, not on the fabric ───────────────────────────────────────
    # A host can declare its audio backend without joining any device pool (that is exactly what
    # `backend.enable` without `fabric.enable` means), and such a host loses its ALSA enumeration
    # the same way. Everything below this block is fabric machinery and stays gated on the fabric.
    (lib.mkIf cfg.guard.enable {
      systemd.user.services.nixaudio-alsa-guard = {
        description = "Repair a WirePlumber that came up with no ALSA devices (nixaudio)";

        # Pulled in BY wireplumber and stopped WITH it, so it runs once per wireplumber start --
        # which is the moment the failure it looks for is actually created. `bindsTo` rather than
        # `requires` so it never tries to start wireplumber itself; the guard has no opinion about
        # whether audio should be running, only about whether a running session manager found its
        # cards.
        after = [ "wireplumber.service" ];
        bindsTo = [ "wireplumber.service" ];
        partOf = [ "wireplumber.service" ];
        wantedBy = [ "wireplumber.service" ];

        # ConditionUser, for the same reproduced incident this repo's consumers already patch
        # nixaudiod for: systemd.user.services installs into EVERY user's manager, and a root
        # login would otherwise run a guard against a session it cannot see, find no graph, and
        # start restarting another user's wireplumber.
        # optionalAttrs rather than mkIf: this is a plain attribute of a unit definition, not an
        # option definition that needs a priority, and mkIf here would leave an unresolved `_type =
        # "if"` wrapper anywhere the unit is read as data rather than merged as a submodule.
        unitConfig = lib.optionalAttrs (cfg.guard.user != null) {
          ConditionUser = cfg.guard.user;
        };

        # nixpkgs' own PipeWire closure, because on NixOS that is also the daemon that is running
        # -- the client and the server come from one package set. See nixaudio.guard.toolPath.
        # Every bare command used by the probe must be represented here. In particular, gawk is
        # not pulled in by the standard systemd service PATH: without it the repair-budget filter
        # fails after truncating its state file, so every WirePlumber restart becomes "repair 1"
        # and the guard can loop forever instead of stopping at maxRepairs.
        path = lib.optionals (cfg.guard.toolPath == [ ]) [ pkgs.pipewire pkgs.jq pkgs.gawk pkgs.systemd ];

        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${cfg.guard.package}/bin/nixaudio-alsa-guard";
          # The script polls for up to settleSeconds and then acts once; this is a backstop against
          # a pw-dump that never returns, not the normal bound.
          TimeoutStartSec = cfg.guard.settleSeconds + 60;
          # Being SIGTERMed is a NORMAL outcome here, not a failure. The guard is PartOf
          # wireplumber, so stopping wireplumber stops the guard -- and during a RESTART that lands
          # on a guard still inside its settle poll, which systemd would otherwise record as
          # `Failed with result 'signal'` after every single restart. A unit that shows failed when
          # nothing failed is precisely the kind of signal people learn to ignore, which is the
          # habit that let the fabric health check sit latched for ten days. A real fault still
          # exits 1 and still shows failed.
          SuccessExitStatus = "SIGTERM";
        }
        // lib.optionalAttrs (cfg.guard.toolPath != [ ]) {
          Environment = [ "PATH=${lib.concatStringsSep ":" cfg.guard.toolPath}" ];
        };
      };

      systemd.user.timers = lib.mkIf (cfg.guard.interval != null) {
        nixaudio-alsa-guard = {
          description = "Periodic re-check for a WirePlumber with no ALSA devices (nixaudio)";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnUnitActiveSec = cfg.guard.interval;
            OnStartupSec = cfg.guard.interval;
            # Every host firing at the same instant would restart the whole fabric at once; the
            # failure is not time-critical, so smear it.
            RandomizedDelaySec = "30s";
          };
        };
      };

      environment.etc = lib.mkIf
        (cfg.dropIns == "system" && cfg.guard.wireplumberConfig != "")
        {
          "wireplumber/wireplumber.conf.d/50-nixaudio-reservation.conf".text =
            cfg.guard.wireplumberConfig;
        };
    })

    (lib.mkIf cfg.fabric.enable {
      nixaudio.fabric.transport.command = [
        "${pkgs.pipewire.jack}/bin/pw-jack"
        "${cfg.fabric.transport.package}/bin/jacktrip"
      ];

      services.pipewire = {
        enable = lib.mkDefault true;
        alsa.enable = lib.mkDefault true;
        jack.enable = true;
      };

      # WirePlumber rules go through /etc rather than services.pipewire.wireplumber.configPackages so
      # that the exact same rendered text is used on both planes -- a system-manager host has no
      # configPackages equivalent, and one rendering is easier to reason about than two.
      environment.etc = lib.optionalAttrs (cfg.dropIns == "system")
        {
          "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf".text = cfg.namingConfig;
        };
    })

    (lib.mkIf cfg.daemon.enable {
      environment.systemPackages = [ cfg.daemon.package cfg.fabric.transport.package ];
      environment.etc."nixaudio/config.json".source = cfg.daemon.configFile;
      systemd.user.services.nixaudiod = {
        description = "nixaudio PipeWire control plane";
        after = [ "pipewire.service" "wireplumber.service" ];
        wants = [ "pipewire.service" "wireplumber.service" ];
        wantedBy = [ "default.target" ];
        # wpctl lives in wireplumber, not pipewire. Without it every default/volume/mute method
        # fails on NixOS while the Arch plane, which resolves through /usr/bin, appears fine.
        path = [ pkgs.coreutils pkgs.pipewire pkgs.wireplumber ];
        environment.NIXAUDIO_CONFIG = "/etc/nixaudio/config.json";
        unitConfig = lib.optionalAttrs (cfg.daemon.user != null) { ConditionUser = cfg.daemon.user; };
        serviceConfig = {
          ExecStart = "${cfg.daemon.package}/bin/nixaudiod";
          Restart = "always";
          RestartSec = 5;
        };
      };
    })

    (lib.mkIf cfg.tray.enable {
      environment.systemPackages = [ cfg.tray.package ];
      systemd.user.services.nixaudio-tray = {
        description = "nixaudio StatusNotifier frontend";
        after = [ "nixaudiod.service" ];
        wants = [ "nixaudiod.service" ];
        partOf = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];
        unitConfig = lib.optionalAttrs (cfg.daemon.user != null) { ConditionUser = cfg.daemon.user; };
        serviceConfig = {
          ExecStart = "${cfg.tray.package}/bin/nixaudio-tray";
          Restart = "on-failure";
          RestartSec = 2;
        };
      };
    })
  ];
}
