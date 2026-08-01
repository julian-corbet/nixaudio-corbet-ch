# nixaudio.fabric health — notice a broken pool instead of discovering it weeks later.
#
# THE DEFECT THIS EXISTS FOR
#
# The daemon logged `alive: watching 1 peer(s), tunnels=0` every 60 seconds for over five hours and
# nothing anywhere noticed. A daemon that reports its own brokenness to a log nobody reads is not
# monitored; it is just polite about failing.
#
# WHY THE OBVIOUS CHECK IS WRONG
#
# `tunnels == 0` is NOT a fault condition. It is the correct reconciled state whenever no peer is
# currently offering a real device — which happens legitimately: a peer whose only audio device is a
# presence-gated GPU HDMI controller offers nothing when no display is attached, and the loop-guard
# correctly declines to mirror a mirror. Alerting on `tunnels == 0` would have paged constantly and
# been muted within a week, which is worse than no check at all.
#
# The real invariant is RELATIONAL: if a peer is reachable AND offers at least one real
# (non-mirrored) device, this host must hold at least one tunnel to it. Anything else is a genuine
# failure — a wedged daemon, a half-open listener, a peer that answers TCP but not pulse.
{ lib, options, config, pkgs, ... }:
let
  cfg = config.nixaudio.fabric;

  probe = pkgs.writeShellApplication {
    name = "nixaudio-fabric-health";
    runtimeInputs = [ pkgs.pulseaudio pkgs.jq ];
    text = ''
      config_file="''${NIXAUDIO_FABRIC_CONFIG:-/etc/nixaudio/fabric.json}"
      if [ ! -r "$config_file" ]; then
        echo "fabric: no config at $config_file"
        exit 1
      fi

      port=$(jq -r '.port // 4713' "$config_file")
      unhealthy=0
      checked=0

      while read -r peer_host; do
        [ -n "$peer_host" ] || continue

        # A peer that is simply down is not a fault -- a roaming host is expected to come and go.
        # Only a peer we can actually talk to is held to the invariant.
        if ! pactl -s "tcp:$peer_host:$port" info >/dev/null 2>&1; then
          continue
        fi
        checked=$((checked + 1))

        # Real devices only: anything already carrying a fabric prefix is a mirror of someone else,
        # and mirroring a mirror is precisely what the daemon's loop-guard forbids.
        real=$(pactl -s "tcp:$peer_host:$port" list sinks short 2>/dev/null \
          | grep -cve 'fabric_' -e 'fabricsrc_' -e 'tunnel\.' || true)

        if [ "$real" -gt 0 ]; then
          held=$(pactl list modules short 2>/dev/null | grep -c "server=tcp:$peer_host:$port" || true)
          if [ "$held" -eq 0 ]; then
            echo "fabric: peer $peer_host offers $real real device(s) but this host holds no tunnel to it"
            unhealthy=$((unhealthy + 1))
          fi
        fi
      done < <(jq -r '.peers | keys[]' "$config_file")

      if [ "$unhealthy" -gt 0 ]; then
        exit 1
      fi

      echo "fabric: ok ($checked reachable peer(s), all offered devices mirrored)"
    '';
  };
in
{
  options.nixaudio.fabric.healthCheck = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = probe;
    description = ''
      Probe asserting the fabric's real invariant: every reachable peer that offers a real device is
      mirrored here. Exits non-zero with a specific message naming the peer when it is not.

      Exposed as a package regardless of whether nixwatch is composed, so it stays runnable by hand
      and usable from any other scheduler.
    '';
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ cfg.healthCheck ];
    })

    # Register with nixwatch only when nixwatch is actually composed on this host. `options ?
    # nixwatch` is the guard rather than mkIf, because defining an option that does not exist is an
    # eval error no conditional inside the definition can rescue.
    #
    # nixwatch dispatches to nixpush by name and never as a flake input, so declaring the check here
    # is all that is needed -- alerting comes for free and nixaudio never references nixpush.
    (lib.optionalAttrs (options ? nixwatch) (lib.mkIf cfg.enable {
      nixwatch.checks.audio-fabric = {
        probe = "${cfg.healthCheck}/bin/nixaudio-fabric-health";
        interval = lib.mkDefault "5m";
        severity = lib.mkDefault "warning";
      };
    }))
  ];
}
