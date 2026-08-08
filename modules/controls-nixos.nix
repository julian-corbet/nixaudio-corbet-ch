# The NixOS delivery for nixaudio.controls: install the selected control tools from nixpkgs.
#
# WHY THIS IS A PLAIN PACKAGE LIST, where ./backend-nixos.nix is not. That module installs almost
# nothing, because on NixOS `services.pipewire.*` IS the delivery mechanism for the daemon layer and
# a package list beside it would be a second closure of the same sound server. No comparable option
# exists for a mixer or a media controller -- nothing in NixOS gates them, nothing configures them,
# and there is no second copy to collide with. So here the package genuinely is the whole answer,
# which is exactly why `../lib/controls.nix` sets `nixosOption = null` on both entries and why
# `controls.packageNames` is normally the entire selection.
#
# SEPARATE FROM ./backend-nixos.nix rather than three more lines inside it: that module's whole body
# is `lib.mkIf cfg.enable` on the BACKEND's own gate, and a host is entitled to want a mixer without
# handing nixaudio its sound server (an existing NixOS host with `services.pipewire` already set up
# by something else). Folding the two together would silently drop the controls on precisely that
# host.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixaudio.controls;

  path = name: lib.splitString "." name;

  # Same forcing discipline as ./backend-nixos.nix, for the same reason: `hasAttrByPath` reports a
  # THROWING nixpkgs alias as present, so an attribute that exists but cannot be evaluated would be
  # accepted here and fail the build later with an error naming neither this module nor the entry.
  resolves = name:
    lib.hasAttrByPath (path name) pkgs
    && (builtins.tryEval (lib.getAttrFromPath (path name) pkgs)).success;

  package = name: lib.getAttrFromPath (path name) pkgs;

  missing = lib.filter (n: !(resolves n)) cfg.packageNames;
in
{
  config = {
    assertions = [
      {
        assertion = missing == [ ];
        message = ''
          nixaudio.controls: ${toString (builtins.length missing)} nixpkgs attribute(s) do not
          resolve in this nixpkgs: ${lib.concatStringsSep ", " missing}.

          This is a table problem, not a host problem -- a package was renamed, dropped, or turned
          into a throwing alias upstream. Fix lib/controls.nix so every consumer gets the
          correction, rather than pinning an older nixpkgs on one machine.
        '';
      }
    ];

    # Empty unless a host enabled a control, so composing this module changes nothing on its own.
    environment.systemPackages = map package cfg.packageNames;
  };
}
