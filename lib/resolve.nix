#
# Channel resolution: pure functions from a list of selected backend entries to the per-platform
# lists a plane actually consumes.
#
# WHY THESE ARE NOT INLINE IN ../modules/backend.nix, the same reasoning the sibling nixfs and
# nixoffice give for their own copies of this file: inline, the only input they could ever be tested
# against is the REAL table in ../lib/packages.nix, which is what happens to be true today rather
# than a set of inputs chosen to exercise every branch. That table has no `arch = null` entry and no
# `aur = true` entry -- every one of the seven is an official-repo Arch package -- so both of those
# branches would be untested code the day a future entry needs them. Here they can be, and are,
# driven by fixtures in ../checks/default.nix.
#
# EVERY CHANNEL FIELD IS INDEPENDENTLY NULLABLE, which is the rule these functions are written
# around: an entry may name a pacman package, a nixpkgs attribute, a NixOS option, or (for `arch`)
# nothing at all. So anything that REPORTS on an entry reports it by its own table key -- `name`,
# attached by ../modules/backend.nix before calling in here -- never by one of the channel names,
# which may be null exactly when there is something to report.
{ lib }:
rec {
  # The gate filter, applied before every other function here. An entry with `gate = null` is
  # universal; an entry naming a gate appears only when the host has turned that gate on. A gate
  # naming something the caller did not supply is NOT silently false -- `gates.${g}` throws, and
  # ../modules/backend.nix turns that into an assertion instead, because an entry silently dropped
  # for a typo'd gate is the one failure mode this whole layer exists to prevent.
  selected = gates: entries:
    lib.filter (e: (e.gate or null) == null || gates.${e.gate}) entries;

  # Official-repo pacman names. `aur = true` entries are held back for aurPackages: `pacman -S`
  # cannot resolve an AUR name and fails the whole transaction on "target not found", which would
  # take every other package in the same converge down with it.
  archPackages = entries:
    lib.unique (map (e: e.arch)
      (lib.filter (e: (e.arch or null) != null && !(e.aur or false)) entries));

  aurPackages = entries:
    lib.unique (map (e: e.arch)
      (lib.filter (e: (e.arch or null) != null && (e.aur or false)) entries));

  # Entries with no Arch package at all. For an audio BACKEND this is not the benign case it is in
  # the sibling nixfs -- see ../system-manager/default.nix for why it is treated as a table defect
  # to be fixed rather than quietly filled in from nixpkgs.
  unavailableOnArch = entries:
    lib.unique (map (e: e.name) (lib.filter (e: (e.arch or null) == null) entries));

  # What a NixOS host installs from nixpkgs into systemPackages: entries with a nixpkgs attribute
  # and no NixOS option providing them, minus firmware (which the kernel loads from the firmware
  # search path, not from $PATH -- a different delivery, below).
  packageNames = entries:
    lib.unique (map (e: e.nixpkgs)
      (lib.filter
        (e: (e.nixpkgs or null) != null && (e.nixosOption or null) == null && !(e.firmware or false))
        entries));

  firmwareNames = entries:
    lib.unique (map (e: e.nixpkgs)
      (lib.filter (e: (e.nixpkgs or null) != null && (e.firmware or false)) entries));

  # entry name -> the NixOS option that already provides it. Published rather than merely acted on,
  # so a reader can see WHERE each of these comes from on NixOS without reading this module's
  # source, and so a check can assert the boundary rather than infer it.
  providedByNixosOptions = entries:
    lib.listToAttrs (map (e: lib.nameValuePair e.name e.nixosOption)
      (lib.filter (e: (e.nixosOption or null) != null) entries));

  # THE ANTI-SHADOWING INVARIANT, made computable. An entry naming BOTH a nixpkgs attribute and a
  # NixOS option would be installed once by the option and once by this module -- two copies of one
  # tool on one host, which for a sound server means an ambiguity about which daemon the systemd
  # units, the udev rules and the ALSA plugin config actually point at. This must always return the
  # empty list; ../modules/backend.nix asserts exactly that, and a fixture in ../checks proves the
  # assertion is not vacuous.
  shadowed = entries:
    map (e: e.name)
      (lib.filter (e: (e.nixpkgs or null) != null && (e.nixosOption or null) != null) entries);
}
