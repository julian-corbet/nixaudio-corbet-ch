# nixaudio.dropIns — which plane physically places the PipeWire/WirePlumber fragments.
#
# ── THE DEFECT ──────────────────────────────────────────────────────────────────────────────────
#
# A host may legitimately compose TWO of this flake's planes at once: the system one to place config
# where every session reads it, and the home-manager one because that is the only plane with a
# `systemd --user` primitive to run the fabric daemon. Both Arch hosts in the estate this was
# written for do exactly that, and until this option existed BOTH of them wrote the same four
# fragment basenames — one set into `/etc`, one into `~/.config`.
#
# Identical content, so it looked harmless. It is not, because PipeWire does not pick a winner
# between its search roots: it MERGES them, and the merge rule depends on the shape of the section.
#
#   an OBJECT (`context.properties`, `wireplumber.settings`)   later root overrides — harmless
#   an ARRAY  (`pulse.cmd`, `monitor.alsa.rules`)              CONCATENATED — every entry twice
#
# `pulse.cmd` is an array, and its entry is `load-module module-native-protocol-tcp listen=… port=…`.
# So pipewire-pulse ran that command twice in one process: the first bind succeeded, the second
# failed, and every start of both hosts logged
#
#   mod.protocol-pulse: bind() failed: Address already in use
#   default: can't run command load-module module-native-protocol-tcp: Address already in use
#
# deterministically, at every startup, for as long as both planes were composed. Worse, the failed
# load LEAKS its module object (pipewire-pulse creates the module, registers it, then returns on the
# load error without unregistering), so `pactl list modules` shows two listeners where `ss` shows one
# socket — which is why the condition survived so long unnoticed, and why the fabric's own health
# probe must assert the SOCKET rather than the module.
#
# That error was originally read as fallout from a hung process holding the port. It was not; it
# predates the incident and reproduces on a clean boot on a host that never hung.
#
# ── WHY THIS CANNOT BE AN ASSERTION ─────────────────────────────────────────────────────────────
#
# The obvious answer is to detect the double composition and fail the build. It is not available:
# the two planes are evaluated in SEPARATE module trees — a system-manager (or NixOS) evaluation and
# a home-manager one — that never see each other's config. Nothing at eval time on either side can
# know the other exists. So the honest options are a declared fact or a runtime check, and this
# module is the declared fact; `../modules/monitor.nix`'s listener assertion is the runtime check
# that catches a host which got the fact wrong.
#
# ── SETTING IT ONCE FOR BOTH TREES ──────────────────────────────────────────────────────────────
#
# Because it must AGREE across two trees, do not set it twice. Put it in whatever file the consumer
# already imports into every plane — the estate this came from keeps a single shared audio module
# imported unchanged by the system tree and the home tree precisely so that facts which must be
# byte-identical across planes have one home. A value stated in two places is a value that will
# eventually differ in two places.
{ lib, ... }:
{
  options.nixaudio.dropIns = lib.mkOption {
    type = lib.types.enum [ "system" "user" ];
    example = "system";
    description = ''
      Which plane writes the PipeWire and WirePlumber config fragments this flake generates.

      `"system"` — into `/etc/pipewire/…` and `/etc/wireplumber/…`, by the NixOS or system-manager
      plane. Reaches every user session on the host, including one that never runs home-manager.

      `"user"` — into the user's XDG config directory, by the home-manager plane. The right answer
      for a host where nixaudio has no system plane at all.

      EXACTLY ONE PLANE MAY WRITE THEM. Both is not "belt and braces": PipeWire concatenates array
      sections across its search roots rather than choosing between them, so the fabric's TCP
      listener is loaded twice and the second load fails on every start. See this module's header.

      Each plane defaults to its own kind, so a host composing only one plane never has to answer
      this. A host composing BOTH must — and must say the same thing in both trees, which is why it
      belongs in a file shared between them rather than stated twice.
    '';
  };
}
