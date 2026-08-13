# A system and Home Manager evaluation cannot see one another. This declared owner prevents both
# planes from writing the same WirePlumber naming file on a composed Arch host.
{ lib, ... }:
{
  options.nixaudio.dropIns = lib.mkOption {
    type = lib.types.enum [ "system" "user" ];
    example = "system";
    description = ''
      Plane that installs nixaudio's generated WirePlumber naming rules: `system` writes `/etc`,
      while `user` writes the user's XDG configuration. A composed host must choose one owner.
    '';
  };
}
