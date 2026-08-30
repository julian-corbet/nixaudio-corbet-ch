# system-manager plane.
#
# system-manager has no `services.pipewire`, so this plane only projects NixAudio's generated host
# files. Package resolution and command paths belong to the host hub's backend; for Arch/CachyOS
# that is nixarch's `audio-backend`, imported alongside this module.
#
# The inventory, the naming rules, the fabric policy and the backend selection all come from the
# SAME ../modules files the NixOS plane imports. There is exactly one definition; only this
# projection differs.
#
# The shared `backend.nix` import publishes only `nixaudio.want`. This plane never resolves that
# contract itself and therefore remains a system-manager module rather than an Arch module.
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
    ../modules/rt.nix
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

    # PAM is a host concern on a foreign-system plane. Project the same pure limits data the NixOS
    # plane consumes into limits.d; Home Manager cannot grant process limits after login.
    (lib.mkIf cfg.rt.enable {
      environment.etc."security/limits.d/50-nixaudio.conf".text = cfg.rt.limitsConfig;
    })

    (lib.mkIf (cfg.fabric.enable && cfg.dropIns == "system") {
      environment.etc."wireplumber/wireplumber.conf.d/51-nixaudio-names.conf".text =
        cfg.namingConfig;
    })

    # system-manager owns the host-level fabric facts: the listener address and peer table
    # are already declared in this tree, so serialise them once into /etc. Home Manager can then run
    # the user service against this file without repeating either value in its separate evaluation.
    (lib.mkIf cfg.daemon.enable {
      environment.etc."nixaudio/config.json".source = cfg.daemon.configFile;
      environment.systemPackages = [ cfg.fabric.transport.package ];
    })
  ];
}
