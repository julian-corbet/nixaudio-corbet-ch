# Arch/CachyOS plane.
#
# system-manager has no `services.pipewire`, and the distro's own pacman-installed PipeWire is
# already running — so this plane does not install or manage the daemons, it only drops the same
# generated config fragments where the distro's PipeWire will read them. Enabling the units
# themselves belongs to nixarch's foreignServices, which is the family's existing answer for
# pacman-managed systemd units.
#
# The inventory, the naming rules, the fabric policy and the backend selection all come from the
# SAME ../modules files the NixOS plane imports. There is exactly one definition; only this
# projection differs.
#
# ── THE BACKEND HERE IS A PUBLISHED LIST, AND INSTALLS NOTHING ──────────────────────────────────
#
# `nixaudio.backend.archPackages` is resolved by ../modules/backend.nix and left for the host to
# hand to its own reconciler (`nixarch.packages.pacman = config.nixaudio.backend.archPackages;`).
# Two reasons, and neither is style. Wiring a reconciler in here would couple this general flake to
# one deployment's package module — the line every sibling in this family draws. And installing any
# of it from nixpkgs instead would not even work: the distro's own copy comes first on `PATH` and
# is what every application, script and systemd unit on the machine actually reaches, so a pinned
# nixpkgs copy would sit in the profile unused. For a SOUND SERVER it would be worse than unused —
# two PipeWire closures on one host, with the running units, the udev rules and the ALSA plugin
# config pointing at one of them and the pinned pin at the other.
#
# WHICH IS WHY AN ENTRY WITH NO ARCH PACKAGE IS AN ERROR HERE, not a fallback to nixpkgs. The
# sibling nixfs does fall back, correctly: a standalone repair tool has no running counterpart to
# conflict with. This layer has nothing standalone in it — every entry is a daemon, a plugin config
# for that daemon, or a firmware image the kernel loads for it, so a half-nixpkgs backend is a
# split-brain install rather than a partial one. Failing the build names the missing thing exactly;
# quietly filling it in from nixpkgs would produce a host that mostly works.
{ lib, config, ... }:
let
  cfg = config.nixaudio;
in
{
  imports = [
    ../modules/devices.nix
    ../modules/fabric.nix
    ../modules/catalogue.nix
    ../modules/daemon.nix
    ../modules/backend.nix
    # The control layer, published exactly like the backend and installed exactly as little:
    #
    #   nixarch.packages.pacman = config.nixaudio.controls.archPackages;
    #
    # No assertion accompanies it, unlike the backend's `unavailableOnArch` check below, and that
    # asymmetry is deliberate -- see ../modules/controls.nix's own option doc. A daemon with no
    # pacman name would leave this plane writing config for something nothing installed; a mixer
    # with no pacman name is simply a tool this platform does not carry.
    ../modules/controls.nix
  ];

  config = lib.mkMerge [
    (lib.mkIf cfg.backend.enable {
      assertions = [
        {
          assertion = cfg.backend.unavailableOnArch == [ ];
          message = ''
            nixaudio.backend: ${lib.concatStringsSep ", " cfg.backend.unavailableOnArch} has no
            Arch package at all — neither an official repo nor the AUR — and this plane will not
            substitute a nixpkgs copy for it. Every entry in this table is part of one running
            sound server, so a nixpkgs copy alongside the distro's would be a second, competing
            install rather than a missing piece filled in. Add the pacman name to
            lib/packages.nix, or remove the entry.
          '';
        }
      ];
    })

    (lib.mkIf cfg.fabric.enable {
      environment.etc = {
        # /etc/pipewire/*.conf.d is read by the distro's PipeWire exactly as /etc/wireplumber is by
        # WirePlumber, so a system-wide drop-in reaches every user session without touching
        # dotfiles.
        "pipewire/pipewire.conf.d/50-nixaudio-fabric-loops.conf".text =
          builtins.toJSON cfg.fabric.pipewireConfig."50-fabric-loops";

        "pipewire/pipewire-pulse.conf.d/50-nixaudio-fabric-listener.conf".text =
          builtins.toJSON cfg.fabric.pulseConfig."50-fabric-listener";

        "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf".text = cfg.namingConfig;
        "wireplumber/wireplumber.conf.d/52-nixaudio-fabric.conf".text = cfg.fabric.wireplumberConfig;
      };
    })
  ];
}
