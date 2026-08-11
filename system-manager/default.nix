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
    ../modules/dropins.nix
    ../modules/fabric.nix
    ../modules/catalogue.nix
    ../modules/daemon.nix
    ../modules/guard.nix
    ../modules/backend.nix
  ];

  config = lib.mkMerge [
    # This plane writes /etc, which every session on the host reads, so it claims the fragments by
    # default. A host that composes the home-manager plane as well must NOT let both write -- see
    # ../modules/dropins.nix for the deterministic listener failure that produces.
    { nixaudio.dropIns = lib.mkDefault "system"; }

    # The reservation fragment is NOT gated on the fabric: it is backend-level, and a host with
    # declared audio and no device pool loses its cards to the same D-Bus timeout. The guard UNIT is
    # deliberately absent from this plane -- system-manager never reloads the user manager, so a
    # `systemd --user` unit written here would stay inert until the next login. That half belongs to
    # the home-manager plane (../home/fabric-sync.nix), which is why nixaudio's own docs call that
    # plane non-optional on a system-manager host.
    (lib.mkIf (cfg.dropIns == "system" && cfg.guard.wireplumberConfig != "") {
      environment.etc."wireplumber/wireplumber.conf.d/50-nixaudio-reservation.conf".text =
        cfg.guard.wireplumberConfig;
    })

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

    (lib.mkIf (cfg.fabric.enable && cfg.dropIns == "system") {
      environment.etc = {
        # /etc/pipewire/*.conf.d is read by the distro's PipeWire exactly as /etc/wireplumber is by
        # WirePlumber, so a system-wide drop-in reaches every user session without touching
        # dotfiles.
        "pipewire/pipewire.conf.d/50-nixaudio-fabric-loops.conf".text =
          builtins.toJSON cfg.fabric.pipewireConfig."50-fabric-loops";

        "pipewire/pipewire-pulse.conf.d/50-nixaudio-fabric-listener.conf".text =
          builtins.toJSON cfg.fabric.pulseConfig."50-fabric-listener";

        "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf".text = cfg.namingConfig;
      };
    })
  ];
}
