# NixOS resolution for the semantic `nixaudio.want` contract. This is the only backend table in
# NixAudio: nixpkgs is already this repository's package universe. Foreign package names belong to
# the corresponding host hub (nixarch for Arch/CachyOS).
{ lib, pkgs }:
let
  resolve = kind: table: name:
    table.${name} or (throw "nixaudio NixOS backend: unsupported ${kind} role `${name}`");

  known = table: name: name != null && builtins.hasAttr name table;

  graphs = {
    pipewire = true;
  };

  sessionPolicies = {
    wireplumber = true;
  };

  clientProtocols = {
    alsa = true;
    jack = true;
    pulse = true;
  };

  diagnostics = {
    alsa = [ pkgs.alsa-utils ];
  };

  firmware = {
    "intel-sof" = [ pkgs.sof-firmware ];
  };
in
{
  supports = want:
    known graphs (want.graph or null)
    && known sessionPolicies (want.sessionPolicy or null)
    && builtins.all (known clientProtocols) (want.clientProtocols or [ ])
    && builtins.all (known diagnostics) (want.diagnostics or [ ])
    && builtins.all (known firmware) (want.firmware or [ ]);

  packagesFor = want:
    lib.unique (lib.concatMap (resolve "diagnostic" diagnostics) (want.diagnostics or [ ]));

  firmwareFor = want:
    lib.unique (lib.concatMap (resolve "firmware" firmware) (want.firmware or [ ]));
}
