# Behaviours

What nixaudio is for. These are goals, not a roadmap. They are fixed: changing one is a decision,
not a refactor. `studies/` records why the architecture follows from them, and `experiments/`
records what was measured.

## The product

Several computers, one audio system. A stream playing on any of them can be sent to a speaker,
headset or microphone attached to any other — quickly enough to feel local, over whatever networks
those machines happen to be on, with no server in the middle.

This is **remote sound**: you are at one machine and the sound belongs on another. It is not a music
collaboration tool, and musicians are not the audience it is designed around.

## Fixed goals

| Goal | What it means |
|---|---|
| **It just works, reliably** | Reliability is the entire promise. Peers come and go — people close laptops, change networks, lose coverage, travel — and none of that is an error condition or something a user should have to attend to. Sessions re-form by themselves: no restart, no reconnect button, no diagnosis. Intermittency costs audio *quality*; it never costs the session. |
| **Peer to peer** | Media never passes through a server anyone else operates. A relay exists only for peers that cannot reach each other directly, and it forwards ciphertext it cannot read. |
| **Joining is knowing the secret** | Any Internet-connected computer that knows the circle's secret can join it. No accounts, no directory service, no per-device approval step. |
| **Encrypted between peers** | Every byte of media and control between two peers is authenticated and encrypted. The circle secret is what authenticates; it is not itself a media key. |
| **The best available path, invisibly** | nixaudio continuously takes the best path it can get to each peer, and re-takes it as conditions change. Direct or relayed, LAN or Internet, is an implementation detail with no user-facing name. There is no substrate the design prefers and no mode the user selects: you work with the connection you have, because there is nothing else to do with it. |
| **Intent is durable, effect is best-effort** | A route the user set is remembered as *intent*, not as a live link. While its destination is unreachable the sound falls back to something audible here; when the destination returns it reclaims the route with no user action. Losing a peer must never mean losing the sound. |
| **A retransmission is worse than a dropped packet** | Media rides unreliable datagrams on every path. A transport that recovers lost packets by resending them is disqualified as a media path, however convenient it is for control. |
| **One peer's trouble is one peer's trouble** | A control-plane blip must not become an audible dropout, and an unreachable peer costs that peer and nothing else. Absence is never inferred from a single failed exchange. |
| **Household scale** | Up to about a dozen devices in a circle. Design for that number and no more: it makes a full mesh, a shared secret and an in-memory peer table the right answers rather than compromises. |
| **The machines disappear** | Users choose `hyperx` or `speakers` on a named peer. Addresses, PipeWire object IDs, transport channel slices and which path the media took are diagnostics, never the interface. |

## Explicit non-goals

Each of these is a deliberate exclusion, not an omission awaiting a contributor.

- **Video.** A separate product if it is ever built. Nothing here should be bent to accommodate it.
- **Playing music together in time.** A different product with a different threshold — see *What no
  software can do*. nixaudio moves sound between machines and makes no promise about ensemble
  timing, so nothing may be designed around one.
- **Grading the connection for the user.** No tiers, no modes, no quality badges. In a circle of a
  dozen machines some peers are always better connected than others; naming that tells the user
  nothing they can act on, because there is no other connection to switch to. Path quality belongs
  in diagnostics.
- **Mixing.** One volume per stream and one per device — what the operating system already gives us.
  Per-destination faders are not a goal: they would need a gain stage per route, and anyone who
  wants a mixing desk should run a mixing desk.
- **A hosted service.** No accounts, no web console, no billing, no multi-tenancy, no fleet
  management. A circle is configuration, not a tenant.
- **Being a DAW, or a conferencing application.** nixaudio moves audio between machines. What
  produces or consumes it is somebody else's program.
- **Replacing PipeWire or JackTrip.** See constraints.

## Constraints these goals impose

**Upstream JackTrip does the hard real-time work, and we do not fork it.** It already owns the
low-latency UDP, jitter buffering, packet redundancy and multichannel layout. nixaudio pins an
upstream source build and supervises the process; it does not vendor, port or link its code.

The reason is engineering, not licence. Everything load-bearing in JackTrip is MIT — its GPL surface
is the Qt GUI, which the headless build excludes — so vendoring would be permitted. But its data
protocol calls back into the JackTrip mediator across twenty-one methods, so a faithful lift drags
several thousand lines of Qt-typed C++ along with it and forks the wire format, in exchange for a
chokepoint that is the easy part of the problem. Reading it is free and encouraged; copying it buys
very little and costs a fork forever. There is also no library to link against: upstream builds a
single executable and declares no library target.

**PipeWire owns each host's local graph.** Devices, streams, ports, mixing and local policy are its
job. nixaudio never becomes a second media graph.

**Rust owns the product behaviour.** Semantic identity, peer supervision, channel allocation,
linking, persisted intent and the API.

**The security layer is ours, and it sits outside JackTrip.** Classic JackTrip media is
unauthenticated plaintext UDP. Because we do not fork it, encryption cannot live inside it — it
belongs to the connection adapter nixaudio owns, which must be replaceable without touching the
semantic API, the frontend, or the local PipeWire graph.

**Reliability is a property of the transport boundary, not of the supervisor.** Because JackTrip
speaks only to `127.0.0.1` behind the adapter nixaudio owns, a peer changing address, network or NAT
binding is invisible to the media process: it does not restart, because from where it sits nothing
moved. A design that lets a path change reach JackTrip trades an audible gap for nothing.

## Assumed deployment

A circle is a handful of ordinary computers on ordinary Internet connections, most behind NAT. No
overlay network, VPN or static addressing may be assumed — where one exists it is a convenience for
that operator, never a prerequisite the design leans on.

**Members move, and members vanish.** A laptop that is on the LAN in the morning, on a hotspot in
the afternoon and shut in a bag by evening is the ordinary case, not the exception. Membership is an
identity, so changing network changes the path and nothing else: the same peer, the same semantic
outputs, the same remembered routes, waiting to be reclaimed when it comes back.

**nixaudio carries its own audio, and never borrows a general-purpose tunnel.** Where an operator
already runs an overlay, it is tempting to route audio over it and call the transport problem
solved. That is the wrong boundary in both directions. A shared tunnel usually carries bulk traffic
— file shares, backups — and a large transfer starves a 2.7 ms audio packet in a way no jitter
buffer should have to absorb; a userspace overlay also concentrates every peer's traffic on one
core. And it couples liveness: the overlay going down would take the audio with it, for a reason
that has nothing to do with audio. So audio gets its own path, and an overlay is neither a
dependency nor, where it can be avoided, even a route.

## What no software can do

A single mobile access leg costs 20–30 ms round trip before the audio has travelled anywhere, and
its jitter is a property of the radio rather than of the route — it does not improve with a closer
relay or a better path. Wi-Fi is close behind.

This is recorded because it is the reason for a non-goal, not because it is a promise being hedged.
A laggy peer is a fact to be tolerated gracefully, not a bug to be fixed and not a state to be
announced. Playing in time together needs latency below roughly 25 ms one-way against an endpoint
floor near 8 ms, which is unreachable on any mobile connection and unreliable on most others; that
is a different product. nixaudio is remote sound, and remote sound works fine at latencies where
ensemble playing does not.

## Stated future, not a current goal

A native Rust transport, replacing the supervised JackTrip process, is wanted eventually. It is not
scheduled and nothing should be designed around its arrival. The connection adapter boundary above
is what makes it possible later without a rewrite.
