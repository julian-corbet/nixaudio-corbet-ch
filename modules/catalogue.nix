# The declarative catalogue contains only this host's expected hardware. Remote endpoints are
# runtime facts published by their owning daemon; guessing a peer's devices during Nix evaluation
# would make stale, unavailable routes look real.
{ lib, config, ... }:
let
  cfg = config.nixaudio;
  catalogue = lib.listToAttrs (map
    (device: lib.nameValuePair device.name {
      origin = "local";
      peer = null;
      device = device.name;
      description = device.description;
      known = "declared";
    })
    cfg.resolvedDevices);
in
{
  options.nixaudio.fabric.catalogue = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        origin = lib.mkOption { type = lib.types.enum [ "local" ]; };
        peer = lib.mkOption { type = lib.types.nullOr lib.types.str; };
        device = lib.mkOption { type = lib.types.str; };
        description = lib.mkOption { type = lib.types.nullOr lib.types.str; };
        known = lib.mkOption { type = lib.types.enum [ "declared" ]; };
      };
    });
    readOnly = true;
    default = catalogue;
    description = ''
      Stable local devices expected from declarative inventory. Live peer manifests are the sole
      authority for remote endpoints and therefore do not appear in this evaluation-time table.
    '';
  };
}
