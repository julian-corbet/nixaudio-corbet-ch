# nixaudio

`nixaudio` turns PipeWire's implementation graph into a small, stable audio product:

| Layer | Responsibility |
|---|---|
| Nix modules | backend packages, stable hardware names, peer catalogue, listener policy and units |
| `nixaudiod` | the only nixaudio process that observes or changes PipeWire; routes, defaults, health, hotplug and fabric tunnels |
| `nixaudioctl` | diagnosis and scripting through the public D-Bus API |
| `nixaudio-tray` | compositor-independent StatusNotifier frontend; it never calls PipeWire tools |

The normal interface is semantic. It says `local.hyperx` or `studio.shure`, not “node 147” or
“module-tunnel-sink 536870928”. PipeWire IDs are included only in the inspector for diagnosis.

## What works

| Capability | Current implementation |
|---|---|
| Stable local device identity | WirePlumber rules carry `alsa.nixaudio.device` from declared USB or explicit hardware identity onto its nodes |
| Live graph | `pw-dump --monitor` wakes an event-driven semantic rebuild; clients receive a D-Bus `Changed` signal |
| Routing | each playback stream maps to a set of outputs, so one-to-many playback is a first-class route |
| Persistence | explicit stream routes and default input/output intent are atomically stored under `$XDG_STATE_HOME/nixaudio/` |
| Hotplug/restart | remembered intent is reapplied whenever the matching stream and endpoint exist again |
| Device sharing | declared peers are probed and all of their sinks and sources are mirrored through isolated PipeWire tunnel nodes |
| Frontend | StatusNotifier menu with output and microphone defaults, volume/mute, per-stream route checkboxes and peer health |
| Diagnostics | `nixaudioctl inspect` returns the complete versioned semantic snapshot as JSON |

## User model

A route has three visible dimensions:

```text
source stream  ->  device.output
Firefox        ->  local.hyperx
Music player   ->  studio.shure
Music player   ->  local.speakers
```

The location is `local` unless the endpoint belongs to another member of the sharing circle. A
source can select more than one output. Tunnels, ports, channel links and reconnect mechanics stay
inside the backend.

The tray remains usable while the daemon is absent or restarting: it shows a disconnected state and
reconnects. It does not maintain a competing cache or graph writer.

## Runtime API

The session service is `ch.corbet.NixAudio1`, object `/ch/corbet/NixAudio1`, API version 1.

| Method | Meaning |
|---|---|
| `Inspect()` | return the semantic snapshot as versioned JSON |
| `Route(stream, outputs[])` | replace one stream's explicit target set |
| `ClearRoute(stream)` | return the stream to the selected default output |
| `SetDefaultOutput(endpoint)` | select and remember the output default |
| `SetDefaultInput(endpoint)` | select and remember the microphone default |
| `SetVolume(object, value)` | set stream or endpoint volume from `0.0` through `1.5` |
| `SetMuted(object, bool)` | set stream or endpoint mute |
| `Changed(revision)` | notify clients after a semantic graph change |

CLI examples:

```bash
nixaudioctl inspect
nixaudioctl default-output local.hyperx.analog_stereo
nixaudioctl route stream:123 local.speakers.analog_stereo studio.shure.analog_stereo
nixaudioctl mute local.hyperx.analog_stereo on
```

## Declarative use

The flake exports:

| Output | Use |
|---|---|
| `nixosModules.nixaudio` | complete NixOS plane |
| `systemManagerModules.nixaudio` | Arch/CachyOS host configuration under `/etc` |
| `homeManagerModules.nixaudio` | Arch/CachyOS user services, state and tray |
| `packages.<system>.nixaudio` | all three Rust binaries |

Minimal policy:

```nix
{
  nixaudio = {
    backend.enable = true;
    daemon.enable = true;
    daemon.user = "alice"; # NixOS only
    tray.enable = true;

    fabric = {
      enable = true;
      listen.address = "192.0.2.10";
      peers.studio.host = "studio";
    };
  };
}
```

On an Arch host using both system-manager and Home Manager, system-manager owns the generated
`/etc/nixaudio/config.json`; Home Manager uses:

```nix
nixaudio.daemon.externalConfigPath = "/etc/nixaudio/config.json";
```

The runtime package is intentionally unwrapped. NixOS units put the matching nixpkgs PipeWire tools
on `PATH`; Arch units use `/usr/bin`, so the client tools always match the sound server actually
running on that host.

## Device declarations

USB devices normally come from the shared `nixusb.devices` inventory with the `audio` tag. Explicit
hardware uses the same stable-name contract:

```nix
nixaudio.devices.internal = {
  description = "Laptop audio";
  match = { "device.bus-id" = "pci-0000:00:1f.3"; };
};
```

`nixaudio.priorities.<device>.sink` and `.source` tune WirePlumber's default selection. Profile
narrowing uses WirePlumber's `device.profile.name`, never a card ordinal.

## Security boundary

The present sharing transport is PipeWire Pulse TCP over explicitly declared peers. On the deployed
PipeWire generation its cookie is not an authentication boundary; the listener must therefore be
bound and firewalled to a trusted network. Audio is not encrypted by nixaudio today.

This transport is deliberately behind `nixaudiod`. Replacing it with authenticated, encrypted media
transport does not change the tray, D-Bus API, semantic identities or persisted routes. JackTrip is a
strong candidate for that adapter, but it is not claimed or bundled before that work is implemented
and measured.

## Repository map

| Path | Contents |
|---|---|
| `src/` | Rust model, daemon, CLI, tray and fabric reconciler |
| `modules/` | shared Nix policy and NixOS projection |
| `system-manager/` | Arch/CachyOS system projection |
| `home/` | user-service and tray projection |
| `checks/` | pure module contract checks; the Rust package check also runs unit tests |
| `experiments/` | measured investigations retained as evidence |

Build and check on a suitable build host:

```bash
nix flake check
nix build .#nixaudio
```

Licensed under MIT.
