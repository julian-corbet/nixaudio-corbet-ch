# nixaudio.controls — the tools a PERSON uses to drive the graph, selected per host and resolved
# per platform.
#
# THE LAYER ABOVE ./backend.nix, and deliberately a separate one. That module owns what a host must
# have for audio to exist at all, which is why its Arch plane treats a missing pacman name as a
# build error and why every entry it selects is mandatory once enabled. Nothing here is mandatory:
# a host with no mixer has working audio and an inconvenience. Keeping the two apart is what lets
# the backend keep its strictness without applying it to a GTK window.
#
# WHY THE TABLE IS `../lib/controls.nix` AND NOT MORE ROWS IN `../lib/packages.nix`: see that
# file's own header. The short version is that a rejected-entry assertion correct for a daemon is
# wrong for a standalone GUI, and that difference is behavioural rather than decorative.
#
# ── PLANE-NEUTRAL: THIS FILE INSTALLS NOTHING ───────────────────────────────────────────────────
#
# Same split ./backend.nix draws, for the same reasons. It declares WHAT the controls are and
# resolves them per platform; delivery is each plane's business:
#
#   ./backend-nixos.nix           installs `controls.packageNames` from nixpkgs alongside the
#                                 backend's own, because on NixOS a package in the profile IS the
#                                 delivery for a tool nothing else provides.
#   ../system-manager/default.nix publishes `controls.archPackages` for the host's own pacman
#                                 reconciler and installs nothing, because on Arch the distro's
#                                 copy is the one on PATH.
#
# A consumer on Arch connects the published list itself, exactly as it already does for the
# backend:
#
#   nixarch.packages.pacman = config.nixaudio.backend.archPackages ++ config.nixaudio.controls.archPackages;
#
# ── EVERY ENTRY IS GATED; THERE IS NO UNIVERSAL CONTROL ─────────────────────────────────────────
#
# ./backend.nix's table has one universal set plus a hardware gate, because "PipeWire but not its
# session manager" is not a configuration. Here the opposite holds: a headless host wants the CLI
# and not the GUI, a desktop wants both, a build agent wants neither, and none of those is wrong.
# So this module has no `enable` of its own -- enabling a control IS the opt-in, and a host that
# names none resolves to empty lists rather than to a set of names it would be surprised to find in
# its reconciler.
{ lib, config, ... }:
let
  cfg = config.nixaudio.controls;

  table = import ../lib/controls.nix { };
  resolve = import ../lib/resolve.nix { inherit lib; };

  # Table key attached as `name`, the same idiom ./backend.nix uses: `arch`, `nixpkgs` and
  # `nixosOption` are all independently nullable, so none of them can be relied on for reporting.
  entries = lib.mapAttrsToList (n: v: v // { name = n; }) table.controls;

  # One gate per selectable control. An entry naming a gate that is not here is a table/module
  # mismatch, asserted below rather than silently dropping the entry -- the same failure mode
  # ./backend.nix guards, and the same guard.
  gates = {
    pavucontrol = cfg.pavucontrol.enable;
    playerctl = cfg.playerctl.enable;
  };

  declaredGates = lib.unique (lib.filter (g: g != null) (map (e: e.gate or null) entries));
  unknownGates = lib.filter (g: !(gates ? ${g})) declaredGates;

  # Guarded so a gate typo surfaces as the assertion below rather than as an attribute error
  # thrown from inside `resolve.selected`.
  active = if unknownGates == [ ] then resolve.selected gates entries else [ ];
in
{
  options.nixaudio.controls = {
    pavucontrol.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install the graphical mixer: per-application volume, live per-stream routing between
        sinks, and the card-profile selector. See ../lib/controls.nix's entry for why live stream
        routing is the capability that no configuration file can substitute for, and why a
        fabric host in particular wants it.

        Off by default because it is a GTK window: a headless host, a container without a session
        and a build agent all have working audio and no use for one. A host says so itself rather
        than having it derived from anything -- nothing at evaluation time can see whether a
        person ever sits in front of this machine.
      '';
    };

    playerctl.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install the MPRIS transport controller: play/pause, next, previous, seek and track
        metadata, over `org.mpris.MediaPlayer2`.

        A CLI, so the graphical-session reasoning above does not apply -- it is equally useful
        over SSH, from a status bar, or bound to a media key. Off by default all the same: this
        module never invokes it, and a host that has nothing to bind it to gains nothing from it.

        NOT A VOLUME TOOL. It addresses the playing APPLICATION over D-Bus, where a volume key
        addresses a SINK in the audio graph -- see ../lib/controls.nix's entry for why those two
        keys sitting side by side on one keyboard makes stating this worthwhile.
      '';
    };

    # ── Computed, read-only ──────────────────────────────────────────────────────────────────
    selection = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The selected controls, by table key -- the plane-neutral answer to "what can a person drive
        this host's audio with", before either plane turns it into packages. The two planes must
        agree on this exactly; only the delivery differs.
      '';
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The selected controls as official-repo pacman names, for the host's own reconciler:

          nixarch.packages.pacman = config.nixaudio.controls.archPackages;

        Empty unless a control is enabled. This module cannot install them on Arch and does not
        try, for the same reason the backend does not: the distro's own copy is first on `PATH`.
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selected controls that live in the AUR rather than an official repo, kept SEPARATE because
        `pacman -S` cannot resolve them -- it fails the whole transaction with "target not found",
        taking every other declared package with it:

          nixarch.packages.aur = config.nixaudio.controls.aurPackages;

        Always empty for the current table, and wired anyway so a consumer's configuration does
        not have to change the day one is not.
      '';
    };

    packageNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        What a NixOS host installs from nixpkgs, as attribute names. Unlike the backend's, this is
        normally the whole selection: no `services.pipewire.*` option installs a mixer or a media
        controller, so there is nothing here for an option to provide instead.
      '';
    };

    providedByNixosOptions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = ''
        Entry name -> the NixOS option that already provides it, for entries this module must
        therefore NOT install as a package. Empty for the current table; published rather than
        merely acted on, so the boundary between the two planes stays readable and checkable
        exactly as it is for the backend.
      '';
    };

    unavailableOnArch = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selected controls with no Arch package at all, named by table key. Empty for the current
        table.

        REPORTED, NOT ASSERTED -- and that is the one place this module deliberately differs from
        the backend. There, a missing pacman name fails the build, because every entry is part of
        one running sound server and a nixpkgs copy alongside the distro's would be a second,
        competing install. A control is a standalone program with no running counterpart to
        conflict with, so its absence on one platform is a fact worth surfacing rather than a
        reason to refuse to build a host.
      '';
    };
  };

  config = {
    nixaudio.controls = {
      selection = map (e: e.name) active;
      archPackages = resolve.archPackages active;
      aurPackages = resolve.aurPackages active;
      packageNames = resolve.packageNames active;
      providedByNixosOptions = resolve.providedByNixosOptions active;
      unavailableOnArch = resolve.unavailableOnArch active;
    };

    assertions = [
      {
        assertion = unknownGates == [ ];
        message = ''
          nixaudio.controls: ../lib/controls.nix names ${toString (builtins.length unknownGates)}
          gate(s) this module does not answer: ${lib.concatStringsSep ", " unknownGates}. Every
          gated entry is currently being dropped, silently and completely. Add the gate to `gates`
          in modules/controls.nix (with its own option), or fix the entry's `gate` field.
        '';
      }
      {
        # Structural: ../lib/controls.nix sets exactly one of `nixpkgs` / `nixosOption` per entry,
        # so this cannot fire from a host's configuration -- only from a table edit that would put
        # two copies of one tool on a NixOS host.
        assertion = resolve.shadowed entries == [ ];
        message = ''
          nixaudio.controls: ${lib.concatStringsSep ", " (resolve.shadowed entries)} name(s) BOTH a
          nixpkgs attribute and a NixOS option in lib/controls.nix. On a NixOS host that installs
          the same thing twice: once because the option pulls it in, once because this module does.
          Set `nixpkgs = null` on any entry an option already provides.
        '';
      }
    ];
  };
}
