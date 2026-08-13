# nixaudio.guard — notice that WirePlumber came up with NO devices, and put it back.
#
# ── THE INCIDENT THIS IS FOR ────────────────────────────────────────────────────────────────────
#
# A laptop on this fabric had no local audio for 1h45m. Not degraded: `pactl list short cards` was
# EMPTY while `/proc/asound/cards` listed all four and `aplay -l` worked. The only sinks left were
# the fabric's own tunnels, so the default sink silently became a network mirror of another host and
# the machine went quiet. Nothing alerted, because nothing was down — pipewire ran, pipewire-pulse
# answered every query, wireplumber was `active (running)`. The graph was simply empty.
#
# The chain, reconstructed from the journal and the kernel log rather than guessed:
#
#   1. A system-wide btrfs transaction stall put wireplumber into uninterruptible D state, inside
#      its own atomic state-file save. (This is routine, not exotic: the orphaned zero-byte
#      `~/.local/state/wireplumber/*.<tmp>` files each mark one unclean kill, and there were ~19 of
#      them spanning weeks.)
#   2. `pactl info` stopped answering, so the former fabric process restarted the
#      audio stack.
#   3. systemd could not kill the old wireplumber. A task in D state never reaches signal delivery,
#      so SIGKILL was queued twice and ignored; after 40s systemd logged `Found left-over process
#      ... Ignoring` and started the new instance anyway.
#   4. The old instance still owned every `org.freedesktop.ReserveDevice1.AudioN` D-Bus name. The
#      new one asked for them, the frozen owner never answered `RequestRelease`, the acquire
#      transition timed out into BUSY — and WirePlumber's ALSA monitor only calls `createDevice`
#      for a reservation that reaches `acquired`. So it created NONE. Not "some": none.
#   5. Nothing re-checked. WirePlumber builds its ALSA monitor exactly once per process and has no
#      rescan verb; the liveness probe asked only whether pactl answered, which it did.
#
# Steps 1–4 are addressed at their own layer (`nixaudio.reserveDevice` removes the D-Bus
# arbitration). This module owns step 5, and it is the one that generalises: whatever wedges the enumeration next time, a
# session manager that is running with an empty graph is always wrong, and always fixed by
# restarting it.
#
# ── WHY THIS IS A GUARD AND NOT A CHECK ─────────────────────────────────────────────────────────
#
# ./monitor.nix is the fabric's health CHECK: it probes an invariant and exits non-zero so nixwatch
# can alert. This module deliberately does not stop there, for two reasons that are specific to this
# failure and not general enthusiasm for automatic repair:
#
#   * Nobody would be told. nixwatch has no system-manager or home-manager plane at all, so it
#     cannot be scheduled on either Arch host — and those are the two boxes a person actually
#     listens on. An alert-only answer would leave the exact host that failed with no coverage.
#   * The repair is one restart of one unit, with no state to lose. WirePlumber's persistent state
#     (default nodes, routes, stream properties) lives on disk and is reloaded; the cost of a
#     needless restart is a sub-second gap in playback, against a failure whose cost is total
#     silence until a human notices. That asymmetry is what makes repairing correct here and would
#     not hold for, say, a filesystem.
#
# ── THE PREDICATE, AND WHY IT IS NOT AN EQUALITY ────────────────────────────────────────────────
#
# Repair iff BOTH:
#
#   pipewire exposes ZERO ALSA devices          AND   the kernel has at least one card with a PCM
#
# The obvious version — "PipeWire's card count should equal the kernel's" — is wrong on every host
# here, and would have this thing restarting wireplumber forever:
#
#   * A card with no PCM device at all is dropped by PipeWire's own ALSA plugin permanently
#     (`card->ignored`), and one such card exists on two of the three hosts this was built against.
#   * A card can be excluded ON PURPOSE. One host disables its GPU's HDMI audio function outright
#     with a `device.disabled = true` rule, because a container on the same box holds the same
#     kernel device. That is correct configuration, and an equality check would read it as damage.
#   * A profile can legitimately be `off` — an unplugged HDMI output contributes no node and should
#     not.
#
# Zero-versus-nonzero has none of those failure modes, and it is also exactly what the incident
# produced. A partial loss is a different (and unobserved) fault; this module does not claim to
# catch it, rather than pretending to with a rule that cannot hold.
#
# THE KERNEL SIDE IS COUNTED FROM `/proc/asound/pcm`, NOT `/proc/asound/cards`. A card only appears
# in `pcm` once it has a PCM device, which is the same condition PipeWire's ALSA plugin uses to
# decide a card is worth adding at all. Counting `cards` instead would include the very cards
# PipeWire is right to ignore, and turn "correct steady state" into "repair forever".
#
# ── WHY IT CANNOT LOOP, AND WHY THAT NEEDED SAYING OUT LOUD ─────────────────────────────────────
#
# A repair action whose trigger it cannot itself fix is an infinite loop, and this one restarts the
# unit that pulls it in — so the loop is not hypothetical, it is the default. Three things stop it:
#
#   * A BUDGET. At most `maxRepairs` restarts per `repairWindow`, counted in a file under
#     `$XDG_RUNTIME_DIR` (tmpfs: it resets on logout, which is the right lifetime for "have I
#     already tried this session"). On exhaustion the unit FAILS instead of repairing, which is the
#     honest outcome — a graph that stays empty across several restarts is not a race, and a failed
#     user unit is at least visible.
#   * `--no-block`. The guard is `BindsTo=`/`After=` wireplumber, so a blocking `systemctl restart`
#     would wait on a job that is waiting on the guard's own unit to stop. `try-restart --no-block`
#     enqueues and returns.
#   * SILENT EXIT 0 ON EVERY "NOT MY PROBLEM" CASE — no `/dev/snd`, no cards, `pw-dump` unable to
#     reach pipewire at all. That last one matters: if PIPEWIRE is down, restarting WirePlumber
#     fights `pipewire.service`'s own `BindsTo` and achieves nothing.
#
# ── PLANES: THIS IS A `systemd --user` UNIT, SO IT GOES WHERE USER UNITS GO ─────────────────────
#
# Projected by ./nixos.nix and ../home/default.nix, and NOT by ../system-manager/default.nix —
# the same split nixaudiod follows, for a sharper reason than
# symmetry. system-manager can WRITE `/etc/systemd/user/*.service` (a consumer of this flake does
# exactly that for an ordering shim), but it never reloads the user manager, so a unit it writes is
# inert until the next login. A guard that only arms itself after the next reboot is not a guard.
# home-manager's `sd-switch` does reload and restart what it owns, and NixOS owns the user manager
# outright.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixaudio.guard;

  # No `runtimeInputs`, ON PURPOSE, and this is the anti-shadowing rule from ../lib/packages.nix
  # applied to a script instead of a package. `pw-dump` is a PipeWire client speaking the native
  # protocol to a specific running daemon; on an Arch host that daemon is pacman's, first on PATH
  # and the only one there is. Baking a nixpkgs PipeWire into this script would point the probe at
  # a different build of the client than the server it is interrogating, for no benefit. So the
  # script names its tools bare and each plane supplies the PATH that is right for it — nixpkgs
  # closures on NixOS, the distro's own `/usr/bin` on Arch (see `toolPath`).
  #
  # writeShellApplication (not writeShellScript) because it runs shellcheck at build time and sets
  # `set -euo pipefail`: this script's whole job is to be right about a subtle condition on three
  # different systems, and an unquoted expansion here is a wireplumber restart loop there.
  probe = pkgs.writeShellApplication {
    name = "nixaudio-alsa-guard";
    runtimeInputs = [ ];
    text = ''
      # Every exit 0 below is a deliberate "this host is fine, or this is not mine to fix".
      settle=${toString cfg.settleSeconds}
      max_repairs=${toString cfg.maxRepairs}
      window=${toString cfg.repairWindow}

      state_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/nixaudio"
      attempts="$state_dir/guard.attempts"

      # ── Is there anything to guard? ────────────────────────────────────────────────────────
      # A host with no sound hardware reachable at all is not broken, and neither is a container
      # that was never given /dev/snd.
      if [ ! -d /dev/snd ] || [ ! -r /proc/asound/pcm ]; then
        echo "guard: no ALSA hardware visible to this session — nothing to guard"
        exit 0
      fi

      # Cards the kernel has actually given a PCM device. Deliberately NOT /proc/asound/cards:
      # see this module's header on `card->ignored`.
      kernel_cards() {
        cut -d- -f1 /proc/asound/pcm | sort -u | grep -c . || true
      }

      # ALSA devices PipeWire currently exposes. pw-dump talks to pipewire itself, not to the pulse
      # compatibility layer, so this measures the graph rather than a shim on top of it.
      pw_alsa_devices() {
        pw-dump 2>/dev/null \
          | jq '[.[] | select(.type == "PipeWire:Interface:Device")
                     | select(.info.props["device.api"] == "alsa")] | length' 2>/dev/null
      }

      cards="$(kernel_cards)"
      if [ "$cards" -eq 0 ]; then
        echo "guard: kernel has no card with a PCM device — nothing to guard"
        exit 0
      fi

      # ── Settle, then decide ───────────────────────────────────────────────────────────────
      # WirePlumber has no readiness protocol: neither it nor pipewire implements sd_notify, and
      # there is no "first enumeration finished" signal to wait for. So the readiness contract is
      # to poll the condition itself. Observed settle on the slowest host here is ~2.4s; the
      # default deadline is several times that, because being slow to repair costs nothing and
      # repairing a graph that was merely still filling costs an audio glitch.
      devices=""
      for _ in $(seq 1 "$settle"); do
        devices="$(pw_alsa_devices)"

        # Empty means pw-dump could not reach pipewire AT ALL (as opposed to reaching it and
        # finding nothing). pipewire being down is pipewire.service's problem: wireplumber is
        # BindsTo= it, so restarting wireplumber here would fight that unit rather than help it.
        if [ -z "$devices" ]; then
          echo "guard: pipewire is not answering — leaving it to pipewire.service"
          exit 0
        fi

        if [ "$devices" -gt 0 ]; then
          echo "guard: ok ($devices ALSA device(s) for $cards kernel card(s))"
          exit 0
        fi

        sleep 1
      done

      # ── Confirmed: running, reachable, and empty ──────────────────────────────────────────
      mkdir -p "$state_dir"
      now="$(date +%s)"
      cutoff=$((now - window))
      recent=0
      if [ -r "$attempts" ]; then
        # Keep only attempts inside the window, so the budget is a rate and not a lifetime cap.
        awk -v c="$cutoff" '$1 > c' "$attempts" > "$attempts.new" || true
        mv "$attempts.new" "$attempts"
        recent="$(grep -c . "$attempts" || true)"
      fi

      if [ "$recent" -ge "$max_repairs" ]; then
        echo "guard: PipeWire exposes no ALSA device though the kernel has $cards card(s), and" >&2
        echo "guard: $recent repair(s) in the last $window s did not fix it. Not restarting again." >&2
        echo "guard: this is no longer a race — inspect wireplumber's log and /proc/asound." >&2
        exit 1
      fi

      echo "$now" >> "$attempts"
      echo "guard: PipeWire exposes no ALSA device though the kernel has $cards card(s)" >&2
      echo "guard: restarting wireplumber (repair $((recent + 1)) of $max_repairs in $window s)" >&2

      # try-restart, not restart: if wireplumber is not running, something else is already dealing
      # with it. --no-block is mandatory, not tidiness — see this module's header.
      systemctl --user try-restart --no-block wireplumber.service
    '';
  };

  unitDescription = "Repair a WirePlumber that came up with no ALSA devices (nixaudio)";

  reservationConfig = ''
    # Generated by nixaudio.guard -- do not edit.
    #
    # Take WirePlumber out of the org.freedesktop.ReserveDevice1 handshake. See the module's
    # `reserveDevice` option for the incident this prevents.
    wireplumber.profiles = {
      main = {
        support.reserve-device = disabled
        monitor.alsa.reserve-device = disabled
      }
    }
  '';
in
{
  options.nixaudio.guard = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.nixaudio.backend.enable or config.nixaudio.fabric.enable;
      defaultText = lib.literalExpression
        "config.nixaudio.backend.enable, or config.nixaudio.fabric.enable where ./backend.nix is not composed";
      description = ''
        Watch for the one failure this module exists for: WirePlumber running normally with an
        EMPTY graph, while the kernel has cards. See this module's header for the incident.

        Defaults to `nixaudio.backend.enable`, because the condition is a property of the backend
        rather than of the fabric — a host with declared audio and no device pool can lose its
        enumeration exactly the same way. Turning it off is supported and means only that this host
        prefers to notice by ear.

        Read defensively, the same way this repo reads `nixusb`/`nixnet`: the home-manager plane
        does not import ./backend.nix (package selection is a system concern, and on a distro host
        the packages are pacman's), so there the fabric is what there is to follow.
      '';
    };

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alice";
      description = ''
        The user whose PipeWire graph this guards, used ONLY as a `ConditionUser=` on the NixOS
        plane. Null means no condition.

        Null is not a safe default on NixOS and the option exists because of a reproduced incident:
        NixOS's `systemd.user.services` installs a unit into EVERY user's systemd manager, not just
        the intended one. A `machinectl shell` root login once started a second copy of this
        audio daemon with no pipewire-pulse to talk to, which then `Restart=always`-looped for
        an hour racing the healthy instance. A guard is worse in that position than a daemon: a
        stray root copy would find no graph (because root has none), conclude the session is broken,
        and start restarting a unit belonging to a session it cannot see.

        Set it to the same user as `nixaudio.daemon.user` on any NixOS host. It is null
        rather than derived from that option because the guard does not require the fabric, and
        `daemon.user` has no default to fall back to.

        Not used on the home-manager plane, where a user unit is already the user's own by
        construction.
      '';
    };

    settleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = ''
        How long to keep re-checking before concluding the graph really is empty, in seconds
        (polled once per second, and it exits the moment a device appears).

        This is a readiness contract stood in for a missing one: neither WirePlumber nor PipeWire
        implements `sd_notify`, and there is no signal for "the first ALSA enumeration finished", so
        the only honest thing to wait for is the condition itself. Measured settle on the slowest
        host this was measured on is ~2.4s. The default is deliberately many times that, because the two
        errors are not symmetric — waiting too long costs a few more seconds of silence in a case
        that was already going to need repair, while deciding too early restarts a session manager
        that was merely still enumerating.
      '';
    };

    maxRepairs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = ''
        How many restarts this guard may issue within `repairWindow` before it gives up and FAILS
        instead.

        The budget is what makes automatic repair safe to ship: the guard restarts the very unit
        that pulls it in, so without a bound the first false positive becomes an endless restart
        loop and takes audio down harder than the fault it was chasing. Exhausting it is treated as
        information rather than as a reason to keep going — a graph that is still empty after
        several restarts is not losing a race, and one failed user unit is a better outcome than an
        audio device that dies every few seconds.
      '';
    };

    repairWindow = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3600;
      description = ''
        The window `maxRepairs` is counted over, in seconds. Attempts are recorded under
        `$XDG_RUNTIME_DIR`, which is tmpfs — so the budget also resets on logout, which is the right
        lifetime for "have I already tried this in this session".
      '';
    };

    interval = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "5min";
      example = lib.literalExpression "null";
      description = ''
        Also re-check on this cadence (a systemd `OnUnitActiveSec=`), not only when WirePlumber
        starts. Null runs the guard on WirePlumber's start only.

        The start trigger alone would have caught the incident in the header, because a new
        WirePlumber process is exactly what came up empty. The timer covers the case the same
        investigation showed is possible but was not observed: the D-Bus device reservation can be
        LOST at runtime, without any restart, and a graph that empties out mid-session has no start
        event to hang a check on.

        This is only safe because of `maxRepairs`. A periodic repair with no budget is a periodic
        outage the first time the predicate is wrong about a host.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = probe;
      defaultText = lib.literalExpression "the generated nixaudio-alsa-guard script";
      description = ''
        The guard itself, as a package, so it stays runnable by hand — which is how you check
        whether a host is currently in the failed state without waiting for a timer, and how the
        checks in ../checks exercise a real derivation rather than a string.

        It names its tools bare (`pw-dump`, `jq`, `systemctl`, `awk`) and inherits PATH from
        whatever runs it; see `toolPath` for why that is deliberate rather than sloppy.
      '';
    };

    reserveDevice = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Let WirePlumber take part in the `org.freedesktop.ReserveDevice1` D-Bus handshake, by which
        audio applications ask each other to hand over an ALSA card. Default OFF, which is the
        opposite of upstream's, and the reason is the incident in this module's header.

        THIS IS THE MECHANISM THAT TURNED A HUNG PROCESS INTO A TOTAL BLACKOUT. WirePlumber's ALSA
        monitor creates a device only once its reservation for that card reaches `acquired`. When a
        second instance starts while the first is frozen, it asks the frozen owner to release; the
        owner never answers; the acquire transition times out and settles the reservation into
        `busy`; and the monitor then creates NO device for that card. Not a degraded card — none.
        That is why the observed failure was an empty graph rather than a partial one, and it is why
        turning this off is a fix rather than a workaround.

        WHAT IT COSTS, STATED PLAINLY: cooperative handover with another sound server. If a host
        runs a bare JACK server, or PulseAudio proper, or anything else that wants exclusive use of
        the same card and speaks this protocol, leave it ON — the arbitration is doing real work
        there and losing it means two programs opening one card. On a host where WirePlumber is the
        only participant, the handshake has nobody to negotiate with and its only remaining effect
        is this failure mode. Check before deciding rather than assuming:

            busctl --user list | grep ReserveDevice1

        If every name is owned by wireplumber, there is nothing to cooperate with.

        Upstream ships the same two lines this renders, in a profile block (`mixin.systemwide-
        session`) that the default `main` profile does not inherit — so the reservation is active by
        default on an ordinary desktop session, which is exactly where it did the damage.
      '';
    };

    wireplumberConfig = lib.mkOption {
      type = lib.types.lines;
      internal = true;
      readOnly = true;
      default = lib.optionalString (!cfg.reserveDevice) reservationConfig;
      defaultText = lib.literalExpression "the reservation-disabling profile block, unless reserveDevice";
      description = ''
        Generated WirePlumber config for the reservation decision, consumed by whichever plane is in
        use. Empty when `reserveDevice` is on, since that is upstream's own behaviour and needs no
        fragment.
      '';
    };

    toolPath = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/usr/bin" ];
      description = ''
        Directories prepended to the guard unit's `PATH`. Empty means the plane's own default.

        This exists because `pw-dump` must be the CLIENT MATCHING THE RUNNING SERVER, which is the
        same anti-shadowing rule ../lib/packages.nix applies to the daemons themselves. On NixOS the
        server is nixpkgs' and the NixOS plane wires the nixpkgs closure automatically, so this stays
        empty. On an Arch host the server is pacman's, and the home-manager plane has no system PATH
        of its own to inherit — a unit there gets the user manager's environment, which on a
        graphical session includes `/usr/bin` but on a lingering headless one may not. Setting
        `[ "/usr/bin" ]` there states the requirement instead of relying on it.
      '';
    };
  };

  # No `config` section, deliberately — same reason ./daemon.nix has none. This file defines a
  # package and its settings and nothing that assumes a plane's option surface, which is what makes
  # it importable into a home-manager module tree as readily as a NixOS one. The two projections
  # live in ./nixos.nix and ../home/default.nix.
}
