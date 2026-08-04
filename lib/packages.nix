#
# The audio BACKEND, as a table: what actually has to be present for a host to have audio at all,
# named once per platform.
#
# WHY THIS TABLE EXISTS. Everything else in this repo describes audio that is ALREADY RUNNING --
# ../modules/devices.nix renames nodes the ALSA monitor has already created, ../modules/fabric.nix
# hangs a listener off pipewire-pulse, ../modules/monitor.nix probes a graph. Every one of those is
# a pure function of declared data that renders a config fragment, and a config fragment for a
# daemon that is not installed is an empty gesture. Naming the daemons here is what closes that gap:
# the module that OWNS the audio policy also owns the packages the policy is written against, rather
# than assuming each consumer installed a compatible set by hand.
#
# ── WHY THIS IS NOT lib/catalogue.nix, like the sibling nixfs ────────────────────────────────────
#
# ../modules/catalogue.nix already owns the word "catalogue" in this repo, for a completely
# different table: the stable DEVICE NAMES a consumer looks up instead of parsing a live tunnel
# description. Two tables called "the catalogue" in one flake would be a naming collision in exactly
# the domain this repo exists to keep names straight in. The SHAPE below is the family's shared
# catalogue shape (nixfs/lib/catalogue.nix, nixdev/lib/tools.nix, nixoffice/lib/tools.nix) entry for
# entry; only the filename differs.
#
# ── THE ENTRY SHAPE ──────────────────────────────────────────────────────────────────────────────
#
#   arch         the pacman package name, or `null` where Arch has nothing at all. Every entry
#                below has a real official-repo name; the `null` branch is a capability of the
#                resolution (../lib/resolve.nix), exercised by a fixture in ../checks, not by a live
#                entry.
#   aur          `true` where the Arch name lives in the AUR rather than an official repo, so it can
#                be held back into a separate list: `pacman -S` cannot resolve an AUR name and fails
#                the WHOLE transaction on "target not found". No entry here is AUR today -- all
#                seven are official-repo -- but the field is honoured for shape-consistency with the
#                sibling catalogues.
#   nixpkgs      the nixpkgs attribute this module INSTALLS on a NixOS host.
#   nixosOption  the NixOS option that ALREADY provides this entry, so this module must not install
#                it a second time.
#
# ── EXACTLY ONE OF `nixpkgs` / `nixosOption`, NEVER BOTH: THE ANTI-SHADOWING INVARIANT ───────────
#
# `nixpkgs = null` on the five PipeWire entries below does NOT mean "nixpkgs does not have this".
# It means "on NixOS this arrives through an option, and naming a package here as well would install
# a second copy of something the option already installed". That is the whole hazard: a host with
# two PipeWire closures does not get redundancy, it gets an ambiguity about which daemon the units,
# the udev rules and the ALSA plugin config actually point at.
#
# It is also literally true for three of them that there is no package to name -- verified against
# the pinned nixpkgs, not assumed:
#
#   pkgs ? pipewire-pulse       -> false
#   pkgs ? pipewire-alsa        -> false
#   pkgs ? pipewire-audio       -> false
#   pkgs ? alsa-card-profiles   -> false
#
# nixpkgs ships ONE `pipewire` derivation carrying all of it: `share/alsa-card-profile/mixer/
# profile-sets/` (Arch splits this out as `alsa-card-profiles`), `lib/spa-0.2/bluez5` built against
# `ldacbt`, `libfreeaptx`, `liblc3`, `sbc` and `fdk-aac` (Arch's `pipewire-audio` codec set), and the
# `pipewire-pulse` binary itself. The NixOS options do not install different packages; they switch
# on different parts of the same one:
#
#   services.pipewire.enable             environment.systemPackages/systemd.packages/
#                                        services.udev.packages = [ pipewire ]
#   services.pipewire.wireplumber.enable  environment.systemPackages = [ wireplumber ]; defaults to
#                                        services.pipewire.enable
#   services.pipewire.alsa.enable        /etc/alsa/conf.d/{49-pipewire-modules,50-pipewire,
#                                        99-pipewire-default}.conf pointing at
#                                        ${pipewire}/lib/alsa-lib/libasound_module_pcm_pipewire.so
#                                        -- which is exactly what Arch's `pipewire-alsa` package IS
#   services.pipewire.pulse.enable       un-masks pipewire-pulse.{service,socket}
#
# So the divide is not a package-name mapping with a gap in it. On Arch the packages ARE the
# mechanism and must be installed; on NixOS the option is the mechanism and the package comes with
# it. The table states both, and ../lib/resolve.nix can therefore prove no entry is ever delivered
# twice.
#
# ── DELIBERATELY NOT HERE ───────────────────────────────────────────────────────────────────────
#
# Recorded as data (`rejected`, below) rather than as a comment, so ../checks can assert that
# neither of them ever reaches an output list -- a decision that is only in a comment is one
# refactor away from being undone by accident.
#
# `pipewire-zeroconf` is NOT among them, despite this module refusing to use zeroconf as a fabric
# transport. Being useless to the fabric is not the same as being unwanted on the host: it also
# carries RAOP/AirPlay discovery for third-party network sinks, which is a capability of its own.
# It is in the universal set below, with that distinction stated on the entry.
#
# Frontend/GUI tooling is out of scope by construction: a patchbay, a mixer applet or a tray is
# something a PERSON runs, which makes it a desktop selection, not the sound server. This table is
# the daemon layer a host has to have before any of that has anything to talk to.
{ ... }:
{
  # ── The backend proper ──────────────────────────────────────────────────────────────────────
  # Not a selection. There is no host that wants "PipeWire but not its session manager", or a
  # fabric listener with no pulse layer to host it -- those are not configurations, they are broken
  # installs. So there is one universal set (`gate = null`, i.e. every host that enables the
  # backend), plus entries gated on a hardware fact no software can derive.
  packages = {
    pipewire = {
      arch = "pipewire";
      nixpkgs = null;
      nixosOption = "services.pipewire.enable";
      reason = "the sound server itself -- the daemon every other entry here exists to feed or extend";
    };

    wireplumber = {
      arch = "wireplumber";
      nixpkgs = null;
      nixosOption = "services.pipewire.wireplumber.enable";
      reason = ''
        the session/policy manager, and NOT optional: PipeWire on its own creates no device nodes
        and performs no routing. It is WirePlumber's ALSA monitor that enumerates cards into nodes,
        and WirePlumber's rules engine that reads the naming and priority fragments this repo
        generates (../modules/devices.nix, ../modules/fabric.nix). Without it a host has a running
        daemon, an empty graph, and a set of rules nothing ever evaluates.
      '';
    };

    "pipewire-pulse" = {
      arch = "pipewire-pulse";
      nixpkgs = null;
      nixosOption = "services.pipewire.pulse.enable";
      reason = ''
        MANDATORY for this module specifically, not merely common: the fabric's own
        `module-native-protocol-tcp` listener is loaded INTO pipewire-pulse (see
        ../modules/fabric.nix's pulseConfig, and ../modules/nixos.nix, which already states
        "pipewire-pulse is not optional for this module"), and the mirroring daemon speaks to the
        graph through it. It is also what nearly every application actually speaks. A host without
        it does not get a degraded fabric, it gets no fabric at all.
      '';
    };

    "pipewire-alsa" = {
      arch = "pipewire-alsa";
      nixpkgs = null;
      nixosOption = "services.pipewire.alsa.enable";
      reason = ''
        routes ALSA-NATIVE clients into PipeWire instead of letting them open `hw:` directly. This
        is a correctness fix, not a convenience: an application that seizes the hardware device
        exclusively (mpv -ao=alsa, aplay, a game with its own ALSA path) locks every other stream
        out of that card for as long as it runs -- including the fabric's own mirror of it. It is a
        config drop-in, not a daemon: on Arch a package, on NixOS three files in /etc/alsa/conf.d.
      '';
    };

    "pipewire-audio" = {
      arch = "pipewire-audio";
      nixpkgs = null;
      # The Arch meta's payload lives inside the one `pipewire` derivation on nixpkgs -- see this
      # file's header for the verified attribute-absence and the store-path evidence. So the option
      # that installs pipewire is what provides this entry there.
      nixosOption = "services.pipewire.enable";
      reason = ''
        Arch's "audio support" meta: `alsa-card-profiles` (the profile sets behind every "Analog
        Stereo Output"-style card profile -- without them a card enumerates with no usable profile)
        plus the Bluetooth codec set (LDAC/aptX/AAC/LC3/SBC). Small enough that gating it on
        hardware would cost more in conditional logic than it could ever save, and wrong in
        principle: a Bluetooth headset is exactly the kind of device that shows up on a machine
        that did not have one yesterday.
      '';
    };

    "pipewire-zeroconf" = {
      arch = "pipewire-zeroconf";
      nixpkgs = null;
      # Same story as pipewire-audio: nixpkgs' one `pipewire` derivation already carries
      # lib/pipewire-0.3/libpipewire-module-{zeroconf-discover,raop-discover,raop-sink}.so, linked
      # against avahi -- verified by reading the built store path, not assumed from the build
      # inputs. There is no separate attribute to name, so the option that installs pipewire is
      # what provides this entry.
      nixosOption = "services.pipewire.enable";
      reason = ''
        NOT what the fabric runs on, and that is worth stating plainly so nobody re-derives it:
        this module's device pool is `module-native-protocol-tcp` over declared peers, and
        ../modules/fabric.nix's own header rejects zeroconf as a TRANSPORT for it on the merits --
        mDNS/LAN-only so it cannot traverse a routed overlay, a manual per-sink publish so it is
        not discovery in any useful sense, and a standing bug that filters sources out entirely,
        which alone disqualifies it for a fabric that has to mirror microphones in both directions.
        None of that is a reason not to HAVE it, because the package is not only a fabric
        transport: it is also the discovery half for third-party network sinks a host did not
        declare -- an AirPlay/RAOP receiver, a networked speaker announcing itself on the LAN --
        which is a separate capability from the pool this module manages, and one a host is
        entitled to keep available. Declared, therefore, and deliberately unused by the fabric.
      '';
    };

    "alsa-utils" = {
      arch = "alsa-utils";
      # The one entry NO PipeWire option provides on NixOS, so it is the one entry this module
      # installs from nixpkgs there. Verified by forcing the attribute, not by assuming it:
      # pkgs.alsa-utils.outPath evaluates to a real store path.
      nixpkgs = "alsa-utils";
      nixosOption = null;
      reason = ''
        DIAGNOSIS, and it belongs in the backend rather than in a desktop selection. alsamixer is
        the only way to see and clear the hardware-level mute switches and capture toggles that
        PipeWire does not expose -- a muted ALSA control is silence no matter what the graph above
        it says, and no amount of correct routing, priority or mirroring can be debugged past it.
        `aplay -l` / `arecord -l` are likewise the ground truth about what the kernel enumerated,
        underneath whatever the session manager decided to show. A host that can render audio but
        cannot find out why it is silent is not fully equipped.
      '';
    };

    # ── Hardware-gated: default OFF, turned on by the host that has the hardware ───────────────
    "sof-firmware" = {
      arch = "sof-firmware";
      nixpkgs = "sof-firmware";
      nixosOption = null;
      # Routed to `hardware.firmware` on NixOS, not to systemPackages: firmware is loaded by the
      # KERNEL out of the firmware search path, and a blob on $PATH is not a blob the kernel can
      # find.
      firmware = true;
      gate = "sofFirmware";
      reason = ''
        Sound Open Firmware: the DSP image an Intel SOF audio card cannot produce sound without --
        not a codec pack, not an optimisation. On such a machine the card enumerates as
        `sof-hda-dsp` and the driver (snd_sof_pci_intel_*) waits for a firmware image it must be
        given; without one there is no sound at all. Gated rather than universal because it is a
        statement about physical hardware: a container shares its host's kernel and has no DSP of
        its own to load anything into, and a virtual machine's emulated audio device needs no
        firmware either. Neither should carry it, and neither can derive that fact for itself --
        which is why this is an option a host answers, not a guess this table makes.
      '';
    };
  };

  # ── Installed on real hosts today, and deliberately NOT declared ────────────────────────────
  # Data, not commentary: ../checks asserts that no name here ever appears in any resolved output.
  # Declaring nothing is not the same as declaring these absent -- an operator removing them from a
  # machine is a separate decision, and this module does not make it. What this table settles is
  # that nixaudio will never be the reason one of them is installed.
  rejected = {
    "alsa-plugins" = ''
      its pulse and jack plugins are exactly what pipewire-pulse and PipeWire's JACK layer replace;
      keeping both means two implementations of the same shim, and the ALSA config that decides
      which one a client reaches is the one thing here nobody wants to have to disambiguate live.

      Note what this does and does not say, because a NixOS closure will show the package anyway:
      nixpkgs' alsa-utils wraps its own binaries with ALSA_PLUGIN_DIR pointing at a private
      `all-plugins` union that contains alsa-plugins, so it arrives as alsa-utils' own private
      plugin directory. That is not the case being rejected here. What is rejected is INSTALLING it
      as a package, which on Arch registers its plugins in the system-wide ALSA config where every
      client resolves them -- a competing shim in the path clients actually take, rather than a
      private directory one wrapper looks in.
    '';

    "alsa-firmware" = ''
      firmware for pre-DSP era cards (Emu10k1 and relatives). Unrelated to Intel SOF hardware, which
      is what `sof-firmware` above covers; a modern host has no card that loads any of it.
    '';
  };
}
