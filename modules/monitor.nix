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
#
# WHAT THIS PROBE STILL CANNOT SEE, AND WHO DOES INSTEAD
#
# A peer whose own PipeWire has lost every ALSA device answers TCP, answers pulse, and offers zero
# real devices — so `real=0` and this check skips it as healthy. That is the exact shape of the
# 2026-08-11 outage, and this probe was structurally incapable of catching it. It is not fixed here,
# because it cannot be: from across the fabric, "a peer with no cards" and "a peer whose cards are
# all legitimately absent right now" are the same observation. It is fixed at the only place that
# CAN tell them apart, on the peer itself — see ./guard.nix.
#
# Two things that ARE this probe's business were broken and are fixed below: it could not reach the
# local graph at all when run by a scheduler, and it tested the listener by asking for a module
# object rather than a socket.
{ lib, options, config, pkgs, ... }:
let
  cfg = config.nixaudio.fabric;

  probe = pkgs.writeShellApplication {
    name = "nixaudio-fabric-health";
    runtimeInputs = [ pkgs.pulseaudio pkgs.jq pkgs.iproute2 ];
    text = ''
      config_file="''${NIXAUDIO_FABRIC_CONFIG:-/etc/nixaudio/fabric.json}"
      if [ ! -r "$config_file" ]; then
        echo "fabric: no config at $config_file"
        exit 1
      fi

      port=$(jq -r '.port // 4713' "$config_file")
      unhealthy=0
      checked=0

      # ── FIND THE GRAPH THIS PROBE IS SUPPOSED TO BE ASKING ABOUT ─────────────────────────────
      #
      # This probe reports on a USER's PipeWire graph, and it is very often not run BY that user:
      # a scheduler runs it as root. Bare `pactl` then talks to root's own (non-existent) session,
      # gets "Connection refused" for every local query, and the local arm silently evaluates to
      # zero -- which reads as "this host holds no tunnels", i.e. permanently unhealthy.
      #
      # That is not hypothetical. On the host where this was first scheduled, the check latched into
      # a DOWN state on its very first run and stayed there for nine days without a second alert,
      # because the alerting wrapper only fires on a transition. It was blind for the entire window
      # in which the fabric actually broke.
      #
      # So: find the session's socket and ADDRESS IT DIRECTLY. One socket means one session and no
      # ambiguity; several means the host must say which.
      #
      # ── NEVER `export PULSE_RUNTIME_PATH` HERE. IT IS DESTRUCTIVE WHEN RUN AS ROOT. ───────────
      #
      # libpulse does not merely READ the directory that variable names -- it "secures" it, which
      # means chowning it to the CALLING uid and setting 0700. Point root's libpulse at a user's
      # runtime directory and it takes ownership of it, after which that user can no longer traverse
      # into its own `pulse/native` socket at all.
      #
      # Reproduced, by this very probe, on a live host: an as-root run at 05:21:57 flipped
      # /run/user/1000/pulse to root:root 0700, and 32 seconds later the fabric daemon began logging
      # `local pulse unresponsive` and restarting the audio stack every five minutes -- because its
      # own `pactl` could no longer reach the socket. A health check that breaks the thing it
      # measures is worse than no health check, and this one did it while trying to fix being unable
      # to see.
      #
      # `pactl -s unix:<socket>` takes an explicit server address instead. It opens the socket and
      # nothing else: no runtime directory is consulted, created, chowned or locked.
      server="''${NIXAUDIO_PULSE_SERVER:-}"
      if [ -z "$server" ]; then
        mapfile -t sockets < <(find /run/user -mindepth 3 -maxdepth 3 -path '*/pulse/native' 2>/dev/null)
        if [ "''${#sockets[@]}" -eq 1 ]; then
          server="unix:''${sockets[0]}"
        elif [ "''${#sockets[@]}" -eq 0 ]; then
          echo "fabric: no PipeWire session found (looked for /run/user/*/pulse/native)" >&2
          exit 1
        else
          echo "fabric: ''${#sockets[@]} PipeWire sessions here; set NIXAUDIO_PULSE_SERVER to pick one" >&2
          exit 1
        fi
      fi

      # Fail loudly rather than silently scoring every peer as unmirrored, which is the exact shape
      # of the nine-day false negative above.
      if ! pactl -s "$server" info >/dev/null 2>&1; then
        echo "fabric: cannot reach the local PipeWire graph at $server" >&2
        exit 1
      fi

      # ── THE LOCAL LISTENER MUST BE A SOCKET, NOT A MODULE OBJECT ─────────────────────────────
      #
      # `pactl list modules` is NOT a valid test that peers can reach this host. pipewire-pulse
      # creates and registers the module object BEFORE attempting the bind and does not unregister
      # it when the bind fails -- so a failed listener leaves a module that looks loaded forever.
      # Measured live: two module-native-protocol-tcp objects with identical arguments, one actual
      # socket. Ask the kernel instead.
      listen=$(jq -r '.listen // empty' "$config_file")
      if [ -n "$listen" ] && [ "$listen" != "any" ]; then
        if ! ss -H -ltn | awk '{print $4}' | grep -qxF "$listen:$port"; then
          echo "fabric: nothing is listening on $listen:$port — no peer can reach this host" >&2
          unhealthy=$((unhealthy + 1))
        fi
      fi

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
          held=$(pactl -s "$server" list modules short 2>/dev/null | grep -c "server=tcp:$peer_host:$port" || true)
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
