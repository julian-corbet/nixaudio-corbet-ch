# The NixOS delivery for nixaudio.backend: set the options that ARE the packages here, and install
# from nixpkgs only what no option provides.
#
# WHY THIS IS NOT A PACKAGE LIST. On Arch, "install the audio backend" is `pacman -S pipewire
# wireplumber pipewire-pulse pipewire-alsa pipewire-audio`. There is no NixOS translation of that
# sentence, and writing one would be actively wrong: `pipewire-pulse`, `pipewire-alsa`,
# `pipewire-audio` and `alsa-card-profiles` do not exist as nixpkgs attributes at all (verified
# against the pinned nixpkgs -- see ../lib/packages.nix's header). nixpkgs ships ONE `pipewire`
# derivation containing all of it, and the options below switch on the parts of it a host wants:
# the ALSA plugin config in /etc/alsa/conf.d, the pipewire-pulse units, the udev rules, the
# systemd packages. So on this plane the option IS the mechanism, and the package comes with it.
#
# WHAT IS LEFT FOR THIS FILE TO INSTALL: exactly the entries no `services.pipewire.*` option
# provides -- `alsa-utils` always, `sof-firmware` when the host says it has the hardware. Both are
# genuinely absent otherwise; a NixOS host running PipeWire gets `pactl`, `pw-dump` and `wpctl` and
# still has no `alsamixer` to find a hardware mute with.
#
# THE ANTI-SHADOWING RULE, MECHANICALLY: `cfg.packageNames` is resolved from the entries whose
# `nixosOption` is null, and nothing else here reaches for a package. An entry gaining an option
# without losing its nixpkgs attribute is a build error, not a silently doubled closure -- see
# ../modules/backend.nix's `shadowed` assertion.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixaudio.backend;

  path = name: lib.splitString "." name;

  # `hasAttrByPath` alone is not enough and the difference is not theoretical: a nixpkgs alias that
  # throws on force reports as PRESENT to it, and would be accepted here only to fail the build
  # later with an error naming neither this module nor the entry. Forcing to WHNF under `tryEval` is
  # what actually distinguishes "this attribute resolves" from "this attribute exists".
  resolves = name:
    lib.hasAttrByPath (path name) pkgs
    && (builtins.tryEval (lib.getAttrFromPath (path name) pkgs)).success;

  package = name: lib.getAttrFromPath (path name) pkgs;

  wanted = cfg.packageNames ++ cfg.firmwareNames;
  missing = lib.filter (n: !(resolves n)) wanted;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = missing == [ ];
        message = ''
          nixaudio.backend: ${toString (builtins.length missing)} nixpkgs attribute(s) do not
          resolve in this nixpkgs: ${lib.concatStringsSep ", " missing}.

          This is a table problem, not a host problem -- a package was renamed, dropped, or turned
          into a throwing alias upstream. Fix lib/packages.nix so every consumer gets the
          correction, rather than pinning an older nixpkgs on one machine.
        '';
      }
    ];

    services.pipewire = {
      enable = true;

      # Stated explicitly rather than left to its NixOS default (which merely follows
      # services.pipewire.enable): WirePlumber is where this module's own naming and priority rules
      # are evaluated, and where device nodes come from at all. A host switching it off would keep
      # a running sound server, an empty graph, and a set of rules nothing reads -- as a conflicting
      # definition that is a build error, as a default it would be silence nobody declared.
      wireplumber.enable = true;

      # mkDefault: routing ALSA-native clients through PipeWire is what this backend wants
      # everywhere, but it is the one layer a host might genuinely need to take back (a machine
      # driving hardware from a professional ALSA path of its own). pulse below is NOT mkDefault --
      # see ../lib/packages.nix's pipewire-pulse entry for why it is not negotiable here.
      alsa.enable = lib.mkDefault true;
      pulse.enable = true;
    };

    environment.systemPackages = map package cfg.packageNames;

    # Firmware, not a package on $PATH: the kernel loads a DSP image from the firmware search path,
    # which is what `hardware.firmware` builds. Empty unless the host declared the hardware.
    #
    # NOT a shadow, and worth saying because it looks like one: NixOS's own
    # `hardware.enableRedistributableFirmware` already lists `sof-firmware` among the blobs it
    # installs (nixos/modules/hardware/all-firmware.nix), so on a host with that option on -- the
    # common case -- the same derivation is named twice. `hardware.firmware` is a list of packages
    # linked into ONE search path, so naming an identical store path twice is idempotent: it is the
    # same files, from the same build, in the same place. That is categorically different from the
    # `services.pipewire` case this module refuses, where a second copy would be a second BUILD of a
    # daemon with its own units and its own plugin paths. Declaring it here anyway is what makes the
    # host's need for it explicit rather than a side effect of a general firmware switch that a
    # size-conscious host might one day turn off.
    hardware.firmware = map package cfg.firmwareNames;
  };
}
