# Platform names for the one local audio backend nixaudio supports. NixOS obtains PipeWire
# components through services.pipewire options; Arch obtains the distro packages through the host's
# package reconciler. JackTrip itself is pinned separately by modules/fabric.nix.
{ ... }:
{
  packages = {
    pipewire = {
      arch = "pipewire";
      nixpkgs = null;
      nixosOption = "services.pipewire.enable";
      reason = "local media graph and device/stream API";
    };
    wireplumber = {
      arch = "wireplumber";
      nixpkgs = null;
      nixosOption = "services.pipewire.wireplumber.enable";
      reason = "PipeWire session policy, hardware enumeration and stable naming rules";
    };
    "pipewire-pulse" = {
      arch = "pipewire-pulse";
      nixpkgs = null;
      nixosOption = "services.pipewire.pulse.enable";
      reason = "PulseAudio application compatibility; not a network transport";
    };
    "pipewire-alsa" = {
      arch = "pipewire-alsa";
      nixpkgs = null;
      nixosOption = "services.pipewire.alsa.enable";
      reason = "route ALSA applications into the shared PipeWire graph";
    };
    "pipewire-audio" = {
      arch = "pipewire-audio";
      nixpkgs = null;
      nixosOption = "services.pipewire.enable";
      reason = "Arch audio profiles and codec support carried by PipeWire on NixOS";
    };
    "pipewire-jack" = {
      arch = "pipewire-jack";
      nixpkgs = null;
      nixosOption = "services.pipewire.jack.enable";
      reason = "present JackTrip's JACK ports as ordinary PipeWire ports";
    };
    "alsa-utils" = {
      arch = "alsa-utils";
      nixpkgs = "alsa-utils";
      nixosOption = null;
      reason = "inspect kernel devices and hardware mute controls below PipeWire";
    };
    "sof-firmware" = {
      arch = "sof-firmware";
      nixpkgs = "sof-firmware";
      nixosOption = null;
      firmware = true;
      gate = "sofFirmware";
      reason = "firmware for hosts with an Intel SOF DSP";
    };
  };

  rejected = {
    "alsa-plugins" = "superseded by PipeWire's ALSA and JACK compatibility layers";
    "alsa-firmware" = "unrelated legacy hardware firmware, not Intel SOF";
  };
}
