# nixaudio.backend — the packages the rest of this module's output is written against.
#
# The backend is PipeWire plus its native compatibility layers. JackTrip is not the graph: its JACK
# ports enter that graph through pipewire-jack, while Pulse remains only for ordinary applications.
#
# ── PLANE-NEUTRAL: THIS FILE INSTALLS NOTHING ───────────────────────────────────────────────────
#
# It declares WHAT the backend is and resolves it per platform (../lib/packages.nix, ../lib/
# resolve.nix). Delivery is each plane's own business and looks nothing alike between them:
#
#   ../modules/backend-nixos.nix    sets the `services.pipewire.*` options (which is how the
#                                   packages arrive on NixOS) and installs from nixpkgs ONLY what no
#                                   option provides.
#   ../system-manager/default.nix   publishes `archPackages`/`aurPackages` for the host's own
#                                   pacman reconciler and installs nothing at all, because on Arch
#                                   the distro's copy is the one that runs.
#
# A consumer on Arch connects the published list itself -- wiring a reconciler in here would couple
# this general flake to one deployment's package module, the same line every sibling in this family
# draws:
#
#   nixarch.packages.pacman = config.nixaudio.backend.archPackages;
#   nixarch.packages.aur = config.nixaudio.backend.aurPackages;
#
# ── WHY `enable` FOLLOWS `fabric.enable` ────────────────────────────────────────────────────────
#
# The fabric cannot exist without a local graph, so enabling it also enables this backend.
{ lib, config, ... }:
let
  cfg = config.nixaudio.backend;

  table = import ../lib/packages.nix { };
  resolve = import ../lib/resolve.nix { inherit lib; };

  # Attaches each entry's own table key as `name` -- this table's identity for that entry, since
  # `arch`, `nixpkgs` and `nixosOption` are all independently nullable and none of them can be
  # relied on to exist for reporting. Same idiom as the sibling nixfs's `withName`.
  entries = lib.mapAttrsToList (n: v: v // { name = n; }) table.packages;

  # Every hardware gate this module answers. One entry per gate the table may name; an entry naming
  # a gate that is not here is a table/module mismatch, asserted below rather than silently dropped.
  gates = {
    sofFirmware = cfg.sofFirmware.enable;
  };

  declaredGates = lib.unique (lib.filter (g: g != null) (map (e: e.gate or null) entries));
  unknownGates = lib.filter (g: !(gates ? ${g})) declaredGates;

  # Guarded so the assertion below is what a reader sees on a gate typo, rather than an attribute
  # error thrown from inside `resolve.selected`.
  selectedEntries = if unknownGates == [ ] then resolve.selected gates entries else [ ];

  # A host that has not enabled the backend resolves to nothing at all, rather than to a set of
  # names it would be surprising to find in its reconciler. The outputs are still DEFINED in that
  # case (as empty lists) -- a `mkIf` here would leave read-only options with no definition, so a
  # consumer wiring `nixarch.packages.pacman = config.nixaudio.backend.archPackages` would hit an
  # eval error instead of an empty list.
  active = if cfg.enable then selectedEntries else [ ];
in
{
  options.nixaudio.backend = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.nixaudio.fabric.enable;
      defaultText = lib.literalExpression "config.nixaudio.fabric.enable";
      description = ''
        Whether this host's audio BACKEND -- the sound server, its session manager, the
        compatibility layers every client actually speaks, and the diagnostic tools for when none of
        that produces sound -- is nixaudio's to declare.

        Defaults to `nixaudio.fabric.enable`, because the fabric routes through PipeWire and runs
        JackTrip through PipeWire's JACK compatibility layer. Enabling it without the fabric is a
        supported local-only audio configuration.

        This installs nothing by itself. See this module's header for what each plane does with it.
      '';
    };

    sofFirmware.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install Sound Open Firmware. Turn this on for a host with real Intel DSP audio hardware,
        where it is the difference between working audio and none at all: the card enumerates as
        `sof-hda-dsp` (see `/proc/asound/cards`), the driver is one of the `snd_sof_pci_intel_*`
        modules, and it will not produce sound until it has been handed a firmware image.

        Default OFF, and deliberately not derived from anything. Nothing at evaluation time can see
        which audio hardware a host physically has, and the two ways of being wrong are not
        symmetric: a machine that needs it and lacks it is simply silent, while a machine that
        carries it without the hardware is shipping a DSP image for a DSP it cannot reach. So this
        is a fact a host states about itself.

        WHY A HOST THAT SHARES THE SAME AUDIO DEVICES STILL DOES NOT NEED IT. This is the obvious
        and reasonable objection -- if two machines take turns driving the same headset and
        microphone, why does only one of them get firmware? Because the devices that ROAM and the
        firmware are unrelated things, on two independent grounds:

          * WRONG VENDOR. Sound Open Firmware is an Intel DSP image. A host whose audio silicon is
            AMD (an HDMI/DP audio function on a Radeon card, an HD-audio controller on the chipset)
            enumerates through the generic HDA path and loads no `snd_sof*` module at all; the blob
            is not a smaller benefit there, it is inapplicable.

          * A CONTAINER LOADS NO FIRMWARE. Firmware loading is a kernel operation against the
            kernel's own firmware path. A container shares its host's kernel, cannot write that
            path, and sees the HOST's cards in `/proc/asound/cards`. Files installed inside it
            would never be read by anything.

        And the roaming devices themselves are USB audio class, which needs no firmware whatsoever.
        A host's SOF requirement is for an internal DSP card soldered to that machine -- which,
        being soldered to it, is the one piece of its audio hardware that cannot roam anywhere.
      '';
    };

    # ── Computed, read-only ──────────────────────────────────────────────────────────────────
    selection = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The selected backend entries, by table key -- the plane-neutral answer to "what does this
        host's backend consist of", before either plane turns it into packages or options. The two
        planes must agree on this exactly; only the delivery differs.
      '';
    };

    hardwareGates = lib.mkOption {
      type = lib.types.attrsOf lib.types.bool;
      readOnly = true;
      description = ''
        Every hardware gate this module answers, and whether this host has turned it on. Published
        because the two halves of a gate live in different files -- the entry naming it in
        `lib/packages.nix`, the option answering it here -- and a gate named on one side but not the
        other would otherwise drop its entry silently.
      '';
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The backend as official-repo pacman names, for the host's own reconciler:

          nixarch.packages.pacman = config.nixaudio.backend.archPackages;

        This module cannot install them on Arch and does not try: the distro's own copy is first on
        `PATH` and is the one that runs, so a second copy from nixpkgs would be dead weight that
        also makes the pin decorative. Empty unless `backend.enable`.
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Backend entries that live in the AUR rather than an official repo, kept SEPARATE because
        `pacman -S` cannot resolve them -- it fails the whole transaction with "target not found",
        taking the rest of the converge with it:

          nixarch.packages.aur = config.nixaudio.backend.aurPackages;

        Always empty for the current table -- every entry is an official-repo package -- and wired
        anyway, so a consumer's configuration does not have to change the day one is not.
      '';
    };

    packageNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        What a NixOS host installs from nixpkgs, as attribute names: exactly the entries no
        `services.pipewire.*` option already provides. Read it to see the anti-shadowing rule's
        result directly -- everything else on that plane arrives through an option, and appears in
        `providedByNixosOptions` instead.
      '';
    };

    firmwareNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Firmware entries, as nixpkgs attribute names, kept apart from `packageNames` because they
        are delivered differently: firmware is loaded by the KERNEL from the firmware search path
        (`hardware.firmware` on NixOS), and a blob on `$PATH` is not a blob the kernel can find.
      '';
    };

    providedByNixosOptions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = ''
        Entry name -> the NixOS option that already provides it, for the entries this module must
        therefore NOT install as packages. Published rather than merely acted on: it is the boundary
        between the two planes, and a reader (or a check) should be able to see it without reading
        this module's source.
      '';
    };

    unavailableOnArch = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selected entries with no Arch package at all -- neither an official repo nor the AUR --
        named by table key. Empty for the current table. The Arch plane REFUSES to fill such an
        entry in from nixpkgs and fails instead; see ../system-manager/default.nix for why a
        silently half-installed sound server is worse than a build error.
      '';
    };
  };

  config = {
    nixaudio.backend = {
      selection = map (e: e.name) active;
      hardwareGates = gates;
      archPackages = resolve.archPackages active;
      aurPackages = resolve.aurPackages active;
      packageNames = resolve.packageNames active;
      firmwareNames = resolve.firmwareNames active;
      providedByNixosOptions = resolve.providedByNixosOptions active;
      unavailableOnArch = resolve.unavailableOnArch active;
    };

    assertions = [
      {
        assertion = unknownGates == [ ];
        message = ''
          nixaudio.backend: ../lib/packages.nix names ${toString (builtins.length unknownGates)}
          hardware gate(s) this module does not answer: ${lib.concatStringsSep ", " unknownGates}.
          Every gated entry is currently being dropped, silently and completely, which is exactly
          what a host would NOT notice until the hardware it named was mute. Add the gate to
          `gates` in modules/backend.nix (with its own option), or fix the entry's `gate` field.
        '';
      }
      {
        # Structural: ../lib/packages.nix sets exactly one of `nixpkgs` / `nixosOption` per entry,
        # so this cannot fire from a host's configuration -- only from a table edit that would put
        # two copies of one daemon on a NixOS host.
        assertion = resolve.shadowed entries == [ ];
        message = ''
          nixaudio.backend: ${lib.concatStringsSep ", " (resolve.shadowed entries)} name(s) BOTH a
          nixpkgs attribute and a NixOS option in lib/packages.nix. On a NixOS host that installs
          the same thing twice: once because the option pulls it in, once because this module does.
          For a sound server that is not redundancy -- it leaves which daemon the systemd units,
          the udev rules and the ALSA plugin config point at ambiguous. Set `nixpkgs = null` on any
          entry an option already provides.
        '';
      }
      {
        assertion = config.nixaudio.fabric.enable -> cfg.enable;
        message = ''
          nixaudio: `fabric.enable` requires the PipeWire backend and its JACK compatibility layer.
        '';
      }
    ];
  };
}
