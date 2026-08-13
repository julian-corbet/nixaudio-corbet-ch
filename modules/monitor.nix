# One health surface: ask the daemon for the same semantic snapshot the tray renders. This probe is
# deliberately user-session scoped because both PipeWire and nixaudiod are user-session services.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixaudio;
  probe = pkgs.writeShellApplication {
    name = "nixaudio-health";
    runtimeInputs = [ cfg.daemon.package pkgs.jq ];
    text = ''
      snapshot=$(nixaudioctl inspect)
      status=$(jq -r '.health.status' <<<"$snapshot")
      message=$(jq -r '.health.message' <<<"$snapshot")
      printf 'nixaudio: %s (%s)\n' "$status" "$message"
      test "$status" != error
    '';
  };
in
{
  options.nixaudio.fabric.healthCheck = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = probe;
    description = ''
      User-session probe of nixaudiod's semantic graph health. It requires the same session D-Bus
      as nixaudiod; scheduling and alert delivery remain deployment policy.
    '';
  };

  config = lib.mkIf cfg.fabric.enable {
    environment.systemPackages = [ cfg.fabric.healthCheck ];
  };
}
