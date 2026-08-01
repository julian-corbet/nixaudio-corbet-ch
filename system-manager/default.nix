# Arch/CachyOS plane.
#
# system-manager has no `services.pipewire`, and the distro's own pacman-installed PipeWire is
# already running — so this plane does not install or manage the daemons, it only drops the same
# generated config fragments where the distro's PipeWire will read them. Enabling the units
# themselves belongs to nixarch's foreignServices, which is the family's existing answer for
# pacman-managed systemd units.
#
# The inventory, the naming rules and the fabric policy all come from the SAME ../modules files the
# NixOS plane imports. There is exactly one definition; only this projection differs.
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
  ];

  config = lib.mkIf cfg.fabric.enable {
    environment.etc = {
      # /etc/pipewire/*.conf.d is read by the distro's PipeWire exactly as /etc/wireplumber is by
      # WirePlumber, so a system-wide drop-in reaches every user session without touching dotfiles.
      "pipewire/pipewire.conf.d/50-nixaudio-fabric-loops.conf".text =
        builtins.toJSON cfg.fabric.pipewireConfig."50-fabric-loops";

      "pipewire/pipewire-pulse.conf.d/50-nixaudio-fabric-listener.conf".text =
        builtins.toJSON cfg.fabric.pulseConfig."50-fabric-listener";

      "wireplumber/wireplumber.conf.d/51-nixaudio-names.conf".text = cfg.namingConfig;
      "wireplumber/wireplumber.conf.d/52-nixaudio-fabric.conf".text = cfg.fabric.wireplumberConfig;
    };
  };
}
