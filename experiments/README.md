# experiments

Things tried against the real fleet, with what actually happened. When an experiment settles a
question the conclusion moves to [`../studies/`](../studies/README.md); the experiment stays here as
its evidence.

| Experiment | Question | Outcome |
|---|---|---|
| `pw-dump` property survey | Which PipeWire device properties survive a replug and a reboot? | `device.vendor.id` (`0x`-prefixed), `device.product.id`, `device.bus-id` stable; `api.alsa.path` and `device.bus-path` not. Shaped the matcher design |
| Prior-art re-check (2026-07) | Has upstream shipped anything that replaces the mirroring daemon? | No. AES67 needs PTP + multicast, ROC has no discovery, zeroconf-discover drops sources. Daemon stays |

## Open questions worth an experiment

- **Does a mirror still win the default-sink race on a host with no real output?** Expected yes —
  priority lowering cannot make a sole candidate ineligible. Confirm, and decide whether the fix
  belongs in the consuming app or in a WirePlumber policy this module could own.
- **Does `pactl -s tcp:<name>:4713` re-resolve on reconnect?** The whole nixnet delegation rests on
  a peer NAME being re-resolved after a transport flips. If the tunnel module caches the resolved
  address at load time, roaming needs an explicit tunnel reload on nixnet's publish event.
- **Two units of one model.** The `device.bus-id` regex narrowing is derived from a single device's
  `pw-dump`. Verify with two identical headsets attached at once.
