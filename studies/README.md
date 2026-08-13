# studies

| Topic | Durable conclusion |
|---|---|
| Local graph | PipeWire is the correct per-host graph and policy substrate; replacing it would mean rebuilding Linux audio |
| Media transport | JackTrip already owns the hard real-time UDP, jitter and multichannel work; Rust should supervise it, not clone it |
| Boundary | PipeWire ports exist at both ends of a JackTrip edge. The graph is not “above” JackTrip and JackTrip is not “above” PipeWire |
| Multiplexing | one asymmetric multichannel session per peer pair is enough; streams and sinks are channel slices and PipeWire links |
| Discovery | remote devices are runtime facts announced by their owner, never guesses projected from another host's Nix evaluation |
| Identity | semantic node/device names must survive address failover, replug and PipeWire object-ID churn |
| Security | classic direct JackTrip media is not the final Internet trust boundary; secure pairing/transport remains a separate milestone |
