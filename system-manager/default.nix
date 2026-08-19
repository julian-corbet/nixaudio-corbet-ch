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
{ lib, config, pkgs, ... }:
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
    # the home-manager plane (../home/default.nix), which is why nixaudio's own docs call that
    # plane non-optional on a system-manager host.
    (lib.mkIf (cfg.dropIns == "system" && cfg.guard.wireplumberConfig != "") {
      environment.etc."wireplumber/wireplumber.conf.d/50-nixaudio-reservation.conf".text =
        cfg.guard.wireplumberConfig;
    })

    # ── THE JACK SHIM IS NIX'S, EVEN THOUGH THE SOUND SERVER IS THE DISTRO'S ────────────────────
    #
    # Everywhere else this plane defers to the distro, because the distro's copy is the one that
    # runs. `pw-jack` is the exception, and the reason is an ABI boundary rather than a preference.
    #
    # JackTrip here is the Nix-built binary from `transport.package`. Its RUNPATH names Nix's real
    # libjack2, so the loader resolves `libjack.so.0` inside the store and JackTrip talks to a JACK
    # SERVER that is not running -- "Cannot connect to server socket". `pw-jack` exists to redirect
    # that lookup at PipeWire's implementation, and it does it by prepending a directory to
    # LD_LIBRARY_PATH, which only works when that directory holds an ABI-compatible libjack.
    #
    # Arch's /usr/bin/pw-jack cannot do it, and not by accident: Arch's `pipewire-jack` installs its
    # libjack straight into /usr/lib as the system-wide replacement for jack2 (that is exactly why
    # the two packages conflict), so the script's LD_LIBRARY_PATH line is COMMENTED OUT upstream in
    # the Arch build and it `exec "$@"` unchanged. For a distro binary that is correct and needs no
    # redirect. For ours it is a no-op, verified with ldd both with and without it: the store's
    # libjack2 wins either way.
    #
    # Pointing LD_LIBRARY_PATH at /usr/lib instead would not rescue it. That library is linked
    # against the distro's glibc and our JackTrip against the store's; glibc is the ABI wall, the
    # same one that makes a Nix graphical binary need Nix Mesa.
    #
    # So the shim comes from nixpkgs, matched to the binary it redirects. This is NOT a second sound
    # server: `pw-jack` ships no daemon, and libjack speaks the PipeWire protocol to whichever
    # PipeWire is already listening on the session socket -- the distro's. That boundary is a
    # protocol, not an ABI, and both ends are PipeWire 1.6.x. Proven live on corbet-archlxc: a Nix
    # JackTrip under this shim reaches Arch's running PipeWire and reports "Setting JACK Process
    # Callback... SUCCESS" at 48000/128.
    #
    # `pipewire-jack` stays declared in lib/packages.nix all the same. It is not what wires US up;
    # it is what keeps a real jack2 -- and therefore a real jackd, autostartable by any JACK client
    # that misses its shim -- off a host whose sound server is PipeWire.
    (lib.mkIf cfg.fabric.enable {
      nixaudio.fabric.transport.command = [
        "${pkgs.pipewire.jack}/bin/pw-jack"
        "${cfg.fabric.transport.package}/bin/jacktrip"
      ];
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
      environment.etc."wireplumber/wireplumber.conf.d/51-nixaudio-names.conf".text =
        cfg.namingConfig;
    })

    # system-manager owns the host-level fabric facts on Arch: the listener address and peer table
    # are already declared in this tree, so serialise them once into /etc. Home Manager can then run
    # the user service against this file without repeating either value in its separate evaluation.
    (lib.mkIf cfg.daemon.enable {
      environment.etc."nixaudio/config.json".source = cfg.daemon.configFile;
      environment.systemPackages = [ cfg.fabric.transport.package ];
    })
  ];
}
