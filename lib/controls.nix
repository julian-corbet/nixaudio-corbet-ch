#
# The audio CONTROLS, as a table: the tools a PERSON uses to drive the graph the backend provides.
#
# ── WHY THIS IS A SECOND TABLE AND NOT MORE ROWS IN ../lib/packages.nix ─────────────────────────
#
# That table is the DAEMON LAYER -- the sound server, its session manager, the compatibility shims
# every client speaks, and the diagnostics for when none of it produces sound. Every entry in it is
# a precondition: a host missing one does not have degraded audio, it has a config file for a
# daemon that does not exist, which is why `../modules/backend.nix` treats an entry with no Arch
# package as a build error rather than falling back to nixpkgs.
#
# Nothing here is a precondition for anything. A host with no mixer and no transport control has a
# fully working sound server that a person simply cannot conveniently drive. Mixing the two into
# one table would erase that distinction in the one place it changes behaviour -- the Arch plane's
# "an entry with no pacman name is a table defect" assertion is correct for a daemon and wrong for
# a GUI, which can perfectly well be missing on a headless box.
#
# ── WHY IT IS IN nixaudio AT ALL, RATHER THAN A DESKTOP LAYER ──────────────────────────────────
#
# Because what these tools address is this module's own subject matter: sinks, sources, streams,
# per-application volumes, media players. A desktop layer owns the SESSION -- a compositor, a bar,
# a file manager, a portal -- and knows nothing about the audio graph beyond the fact that one
# exists. `pavucontrol`'s entire content is the PulseAudio/PipeWire object model this repo's device
# names and fabric tunnels are expressed in; a mirrored sink shows up there under the name
# `../modules/devices.nix` gave it. Putting it in a desktop layer would put the reader of a
# device-naming bug two repos away from the tool that displays those names.
#
# It follows that these are not desktop-gated either. A headless host that declares a backend can
# reasonably want `playerctl` (a CLI) and reasonably not want `pavucontrol` (a GTK window) -- so
# each entry has its own gate and none is on by default. This table makes no host's decision.
#
# ── THE ENTRY SHAPE ─────────────────────────────────────────────────────────────────────────────
#
# Identical to ../lib/packages.nix's, field for field, and read by the SAME resolver
# (../lib/resolve.nix) -- there is no second resolution mechanism here, only a second table:
#
#   arch         the pacman package name, or `null` where Arch has nothing.
#   aur          `true` where the Arch name lives in the AUR rather than an official repo.
#   nixpkgs      the nixpkgs attribute this module INSTALLS on a NixOS host.
#   nixosOption  the NixOS option that ALREADY provides this entry, so this module must not install
#                it a second time.
#   gate         which option a host must turn on for this entry to be selected. NEVER null here,
#                unlike the backend table -- there is no such thing as a universal control tool.
#
# ── WHERE THE ARCH PLANE DIFFERS FROM THE BACKEND'S, AND WHY ────────────────────────────────────
#
# The backend refuses to substitute a nixpkgs copy for a missing Arch package, because every entry
# there is part of ONE running sound server and a second closure of it makes which daemon the units
# and the ALSA config point at ambiguous. That reasoning does not reach these: a mixer GUI is a
# standalone program with no running counterpart to conflict with, exactly the case the sibling
# nixfs falls back for. Both entries below have real official-repo Arch names regardless, so the
# question is currently theoretical -- but the distinction is why this table does not inherit the
# backend's assertion.
{ ... }:
{
  controls = {
    pavucontrol = {
      arch = "pavucontrol";
      # Verified by forcing the derivation, not by an attribute-existence check (a throwing alias
      # passes that): `pkgs.pavucontrol.drvPath` evaluates to a real store path, and the top-level
      # name is the GTK program itself -- not a Qt reimplementation under another attribute.
      nixpkgs = "pavucontrol";
      nixosOption = null;
      gate = "pavucontrol";
      reason = ''
        THE MIXER: per-application volume, per-stream device routing, and the card-profile
        selector. What makes it the control tool rather than one of several is the middle one --
        moving a single running application's stream to a different sink is a live operation on
        the graph that no config file can express, because the application was not running when
        the config was written. On a fabric host that is precisely the operation the fabric exists
        to make possible: a mirrored peer sink appears in this window under the name
        ../modules/devices.nix gave it, and sending one program's audio there is two clicks.

        It also shows the object model this repo's own options are written in -- sinks, sources,
        card profiles, stream routes -- which makes it the fastest way to see whether a naming
        rule or a fabric tunnel did what it was declared to do. `alsa-utils` in the backend table
        answers the layer BELOW this one (a hardware mute the graph cannot see); this answers
        everything at and above it.

        Named for what it is: a GTK window. A host without a graphical session should not enable
        it, which is why nothing here does so on its behalf.
      '';
    };

    playerctl = {
      arch = "playerctl";
      # Forced likewise; `pkgs.playerctl.drvPath` is a real derivation and the attribute is the
      # same word as the Arch package, which is not true of every entry in this repo's tables.
      nixpkgs = "playerctl";
      nixosOption = null;
      gate = "playerctl";
      reason = ''
        MPRIS TRANSPORT CONTROL -- play/pause, next, previous, seek, and the current track's
        metadata, spoken to whichever application is playing over the standard D-Bus interface
        (`org.mpris.MediaPlayer2`).

        NOT A VOLUME TOOL, and the distinction is the whole reason it belongs to this repo rather
        than to a compositor's keybind file. A media key that changes volume is acting on the
        AUDIO GRAPH -- a sink's own property, which `wpctl` from the backend's session manager
        sets. A media key that pauses is acting on an APPLICATION, over a bus interface that
        exists whether or not the graph is even routed to a working device. Both keys sit next to
        each other on the same keyboard, which is exactly why the two mechanisms get confused;
        naming them in different tables would not have made them clearer, but stating it here
        does.

        A CLI with no session requirement, unlike the mixer above: it is equally useful over SSH,
        from a bar's status module, or bound to a key. What invokes it is deliberately not this
        module's business -- a compositor keybind, a bar, a script -- and nixaudio never calls it.
      '';
    };
  };
}
