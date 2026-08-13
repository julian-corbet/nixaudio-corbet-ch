# nixaudio control plane

The existing nixaudio modules remain the declarative audio substrate. The next layer is a runtime
control plane with two processes:

- `nixaudiod` is the backend. It is the only nixaudio process allowed to inspect and mutate the
  live PipeWire graph.
- `nixaudio-tray` is the frontend. It presents physical devices, routes and health through a
  StatusNotifier tray item and talks only to `nixaudiod`.

The frontend is not a graph editor. A user should see “Laptop speakers”, “HyperX headset” and
“Studio interface on host-b”, not tunnel nodes, monitor ports and implementation links.

## Ownership

| Owner | Owns | Does not own |
|---|---|---|
| Nix modules | device inventory, stable names, peer policy, packages, permissions, static PipeWire/WirePlumber fragments and units | live routes or remembered user choices |
| PipeWire and WirePlumber | media graph execution, hardware profiles, stream processing and session policy primitives | fleet identity or the nixaudio user experience |
| `nixaudiod` | the semantic live model, route reconciliation, hotplug, health, user intent and the public runtime API | desktop presentation |
| `nixaudio-tray` | display, interaction and notifications | direct PipeWire calls, policy or persistent state |

This also disambiguates the current `nixaudio.backend` Nix option: that option selects the packages
which provide the audio substrate. `nixaudiod` is the runtime backend built on top of that substrate.

## Runtime model

The backend joins two kinds of facts:

1. The declared catalogue says what a device *is*: its stable identity, label, direction and
   physical or remote location.
2. The live PipeWire graph says what exists *now*: profiles, ports, streams, links, reachability,
   volume, mute and errors.

Every public object uses the stable catalogue identity. Volatile PipeWire object IDs stay private
to the backend and may be replaced after any graph restart.

A route is a set, not a single destination:

```text
route = source stream -> { target device, target device, ... }
```

That makes one-to-many playback a first-class operation instead of a sequence of accidental
`move-sink-input` side effects. The backend resolves each target to the current PipeWire nodes and
owns all links created for that route.

User intent is runtime state and belongs under `$XDG_STATE_HOME/nixaudio/`. Nix must never overwrite
it. The backend may use WirePlumber primitives to apply an intent, but it must expose which choice
was explicit, which was remembered, and which was merely selected by priority.

## Backend API

The first API is a session D-Bus service, `ch.corbet.NixAudio1`. It exposes:

- semantic devices and their current availability/location;
- streams and their active target sets;
- default input and output intent;
- fabric-peer and local graph health;
- commands to change a route, default, volume, mute or hardware profile;
- change signals so clients never poll the graph.

`nixaudioctl` uses the same API for diagnosis and acceptance tests. The tray receives no privileged
or hidden path around it.

The API must distinguish these states instead of reducing them all to “audio routed to host-b”:

- a local device is selected;
- a remote physical device is selected through a fabric tunnel;
- an application stream has an explicit route;
- a device is declared but unplugged;
- a peer or tunnel is unavailable;
- the graph is unhealthy.

## Frontend

The tray item has one compact status and one click target. Its main view contains:

- outputs, grouped by physical location, with the active target set visible;
- inputs, with the selected default and per-application use visible;
- active application streams, draggable or assignable to one or more outputs;
- a health row that explains faults in semantic terms;
- an advanced inspector for raw PipeWire names and IDs, kept out of the normal path.

The frontend must remain usable with zero devices, during hotplug, and while the backend is
restarting. It shows disconnected state; it never invents its own cached graph.

## Migration

1. Build a read-only `nixaudiod` model and `nixaudioctl inspect`. Keep the current `fabric-sync`
   daemon and temporary mixer untouched.
2. Add route writes and prove hotplug, graph restart, local/remote selection and one-to-many output
   through CLI acceptance tests.
3. Add the thin tray client against the stable D-Bus API.
4. Move fabric reconciliation and health observation into `nixaudiod`; remove `fabric-sync` in the
   same activation once the replacement passes its acceptance gates. There is no compatibility
   daemon or dual writer.
5. Remove the temporary mixer entry when the tray covers its required controls. Retain standard
   PipeWire command-line tools for diagnosis, not as the product interface.

The first implementation milestone is deliberately read-only. It proves that the semantic model is
correct before a new process is given authority to rewrite a working audio graph.
