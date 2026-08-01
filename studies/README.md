# studies

Durable conclusions, each citing the [`../experiments/`](../experiments/README.md) entry that
produced it.

| Study | Conclusion |
|---|---|
| Device identity | PipeWire exposes USB identity in a *different representation* than udev: `0x`-prefixed lowercase hex, and a `device.serial` that is manufacturer+product+serial mangled, not the raw serial. Any module bridging udev-side and PipeWire-side identity must translate rather than pass through |
| Transport | The cross-host primitives are standard and already in PipeWire; the missing piece is policy, not protocol. A bespoke daemon is justified for the policy layer and nothing more |
| Peer addressing | Hardcoding peer addresses in an application daemon produces two failure modes — silent absence of a host, and total failure while roaming. Address peers by name and let a dedicated failover engine own the mapping |
