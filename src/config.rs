use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    path::PathBuf,
    str::FromStr,
};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    /// Stable member name inside the sharing circle. This is deliberately not a hostname:
    /// hostnames and addresses may change while the member identity must not.
    pub node: String,
    #[serde(default)]
    pub control: ControlConfig,
    #[serde(default)]
    pub transport: TransportConfig,
    #[serde(default)]
    pub peers: BTreeMap<String, PeerConfig>,
    #[serde(default)]
    pub catalogue: BTreeMap<String, CatalogueEntry>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ControlConfig {
    #[serde(default = "default_control_listen")]
    pub listen: String,
    #[serde(default = "default_control_port")]
    pub port: u16,
}

impl Default for ControlConfig {
    fn default() -> Self {
        Self {
            listen: default_control_listen(),
            port: default_control_port(),
        }
    }
}

/// JackTrip's `-q`, with its unit in the type.
///
/// Under `--bufstrategy 3` — the only strategy nixaudio emits — the Regulator reads the numeric
/// form as MILLISECONDS of fixed jitter tolerance with adaptation switched OFF, not as a count of
/// packets. Upstream says so in `JackTrip.cpp`: "bufStrategy 3 or 4, mBufferQueueLength is in
/// integer msec not packets". A plain `u32` invited everyone who read it, including us, to think in
/// packets and ship four milliseconds while believing they had shipped ten.
///
/// `Auto` is the default because it is the only setting that honours "latency is never spent
/// carelessly": the Regulator measures the real link at packet rate and floors its headroom at one
/// period, so it converges on the least buffer the path tolerates instead of on a constant somebody
/// guessed. A fixed value is either too small for the worst path or too large for the best one, and
/// with a dozen members some peer is always on each.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(try_from = "QueueRepr", into = "String")]
pub enum Queue {
    /// `-q auto`: headroom chosen and continuously re-chosen by the Regulator.
    Auto,
    /// `-q auto<N>`: adaptive, seeded with N milliseconds of headroom.
    AutoHeadroom { headroom_ms: u32 },
    /// `-q <N>`: fixed tolerance of N milliseconds, adaptation off.
    FixedMs { ms: u32 },
}

/// Wire spellings accepted for `queue`. The string form is JackTrip's own, so a config file, a Nix
/// option and a hand-typed command line all say the same word. The bare number is the legacy
/// spelling from when this field was a `u32`; it is read as milliseconds, which is what JackTrip
/// always did with it.
#[derive(Deserialize)]
#[serde(untagged)]
enum QueueRepr {
    Text(String),
    Number(u32),
}

impl Queue {
    /// The literal `-q` argument. Total — every variant has a spelling JackTrip accepts.
    pub fn argument(self) -> String {
        match self {
            Queue::Auto => "auto".to_owned(),
            Queue::AutoHeadroom { headroom_ms } => format!("auto{headroom_ms}"),
            Queue::FixedMs { ms } => ms.to_string(),
        }
    }

    /// Whether the Regulator adapts. Only a fixed tolerance freezes it.
    pub fn is_adaptive(self) -> bool {
        !matches!(self, Queue::FixedMs { .. })
    }
}

impl fmt::Display for Queue {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.argument())
    }
}

impl FromStr for Queue {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        if value == "auto" {
            return Ok(Queue::Auto);
        }
        if let Some(headroom) = value.strip_prefix("auto") {
            let headroom_ms = headroom
                .parse()
                .with_context(|| format!("queue {value:?}: expected auto<milliseconds>"))?;
            return Ok(Queue::AutoHeadroom { headroom_ms });
        }
        let ms = value
            .parse()
            .with_context(|| format!("queue {value:?}: expected auto, auto<ms> or <ms>"))?;
        Ok(Queue::FixedMs { ms })
    }
}

impl TryFrom<QueueRepr> for Queue {
    type Error = anyhow::Error;

    fn try_from(value: QueueRepr) -> Result<Self> {
        match value {
            QueueRepr::Text(text) => text.parse(),
            QueueRepr::Number(ms) => Ok(Queue::FixedMs { ms }),
        }
    }
}

impl From<Queue> for String {
    fn from(value: Queue) -> Self {
        value.argument()
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransportConfig {
    /// Command prefix used to launch JackTrip. The final element is the JackTrip executable.
    /// NixOS normally emits [".../pw-jack", ".../jacktrip"], while a foreign distribution can
    /// use its native pw-jack wrapper with the same Nix-built JackTrip binary.
    #[serde(default = "default_command")]
    pub command: Vec<String>,
    /// Host-wide, and deliberately not overridable per peer: PipeWire runs one graph at one clock,
    /// so there is only one of these to have.
    #[serde(default = "default_sample_rate")]
    pub sample_rate: u32,
    /// Defaults for every peer that does not override them. A field is host-wide only when the host
    /// physically has one of it; these four are properties of a link, so each peer may differ.
    #[serde(default = "default_period")]
    pub period: u32,
    #[serde(default = "default_bit_resolution")]
    pub bit_resolution: u8,
    #[serde(default = "default_queue")]
    pub queue: Queue,
    #[serde(default = "default_redundancy")]
    pub redundancy: u8,
}

impl TransportConfig {
    /// This host's defaults, shaped as one peer's resolved parameters — what a peer that overrides
    /// nothing receives.
    pub fn defaults(&self) -> ResolvedTransport {
        ResolvedTransport {
            sample_rate: self.sample_rate,
            period: self.period,
            bit_resolution: self.bit_resolution,
            queue: self.queue,
            redundancy: self.redundancy,
        }
    }
}

impl Default for TransportConfig {
    fn default() -> Self {
        Self {
            command: default_command(),
            sample_rate: default_sample_rate(),
            period: default_period(),
            bit_resolution: default_bit_resolution(),
            queue: default_queue(),
            redundancy: default_redundancy(),
        }
    }
}

/// One peer's overrides. Absent means "take the host default", never "zero".
///
/// This exists because there is exactly one JackTrip process per peer pair, so these were always
/// per-link facts being stored in a host-wide struct. With a dozen members, some well connected and
/// some not, at the same time, a single global tolerance is wrong for somebody by construction.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerTransport {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub period: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bit_resolution: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub queue: Option<Queue>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub redundancy: Option<u8>,
}

/// What one peer's JackTrip process is actually launched with, after overrides are applied.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ResolvedTransport {
    pub sample_rate: u32,
    pub period: u32,
    pub bit_resolution: u8,
    pub queue: Queue,
    pub redundancy: u8,
}

impl ResolvedTransport {
    /// Two period durations, in whole milliseconds, rounded up. A fixed tolerance below this cannot
    /// absorb even one late packet, so it is a configuration that guarantees the glitching it was
    /// meant to prevent.
    pub fn minimum_fixed_ms(&self) -> u32 {
        (2_000 * self.period).div_ceil(self.sample_rate).max(1)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerConfig {
    /// Ordered candidates. The first answering control endpoint also carries the JackTrip client.
    pub addresses: Vec<String>,
    #[serde(default = "default_control_port")]
    pub control_port: u16,
    /// One UDP port per unordered peer pair. Both ends declare the same value.
    pub audio_port: u16,
    #[serde(default)]
    pub transport: PeerTransport,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CatalogueEntry {
    pub origin: String,
    pub peer: Option<String>,
    pub device: String,
    pub description: Option<String>,
    pub known: String,
}

fn default_control_listen() -> String {
    "127.0.0.1".into()
}
fn default_control_port() -> u16 {
    45900
}
fn default_command() -> Vec<String> {
    vec!["jacktrip".into()]
}
fn default_sample_rate() -> u32 {
    48_000
}
fn default_period() -> u32 {
    128
}
fn default_bit_resolution() -> u8 {
    16
}
fn default_queue() -> Queue {
    Queue::Auto
}
fn default_redundancy() -> u8 {
    1
}

pub fn config_path() -> PathBuf {
    std::env::var_os("NIXAUDIO_CONFIG")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/etc/nixaudio/config.json"))
}

impl Config {
    pub fn load() -> Result<Self> {
        let path = config_path();
        let bytes = std::fs::read(&path)
            .with_context(|| format!("read nixaudio configuration {}", path.display()))?;
        let config: Self = serde_json::from_slice(&bytes)
            .with_context(|| format!("parse nixaudio configuration {}", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    /// The transport parameters for one peer's session. An unknown peer resolves to the host
    /// defaults rather than failing, because callers reach this from paths where the peer table has
    /// already been consulted.
    pub fn transport_for(&self, peer: &str) -> ResolvedTransport {
        let mut resolved = self.transport.defaults();
        if let Some(over) = self.peers.get(peer).map(|peer| &peer.transport) {
            resolved.period = over.period.unwrap_or(resolved.period);
            resolved.bit_resolution = over.bit_resolution.unwrap_or(resolved.bit_resolution);
            resolved.queue = over.queue.unwrap_or(resolved.queue);
            resolved.redundancy = over.redundancy.unwrap_or(resolved.redundancy);
        }
        resolved
    }

    pub fn validate(&self) -> Result<()> {
        let valid_member = |name: &str| {
            !name.is_empty()
                && name
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
                && name.as_bytes()[0].is_ascii_alphanumeric()
        };
        if !valid_member(&self.node) {
            bail!("node must match [a-z0-9][a-z0-9-]*");
        }
        if self.control.port == 0 {
            bail!("control.port must be non-zero");
        }
        if self.transport.command.is_empty() || self.transport.command.iter().any(String::is_empty)
        {
            bail!("transport.command must contain a JackTrip command");
        }
        if self.transport.sample_rate == 0 {
            bail!("transport.sampleRate must be positive");
        }
        // The host defaults are validated under their own name, so a bad default is reported as a
        // bad default rather than as a fault of whichever peer happened to inherit it.
        validate_transport("transport", &self.transport_for(""))?;
        let mut audio_ports = BTreeSet::new();
        for (name, peer) in &self.peers {
            if !valid_member(name) {
                bail!("peer {name} must match [a-z0-9][a-z0-9-]*");
            }
            if name == &self.node {
                bail!("peers must not contain this node ({name})");
            }
            if peer.addresses.is_empty() || peer.addresses.iter().any(String::is_empty) {
                bail!("peer {name} needs at least one non-empty address");
            }
            if peer.control_port == 0 || peer.audio_port == 0 {
                bail!("peer {name} needs non-zero controlPort and audioPort");
            }
            if !audio_ports.insert(peer.audio_port) {
                bail!("peer {name} reuses audioPort {}", peer.audio_port);
            }
            validate_transport(&format!("peer {name} transport"), &self.transport_for(name))?;
        }
        Ok(())
    }
}

fn validate_transport(what: &str, resolved: &ResolvedTransport) -> Result<()> {
    if !matches!(resolved.bit_resolution, 8 | 16 | 24 | 32) {
        bail!("{what}.bitResolution must be 8, 16, 24 or 32");
    }
    if resolved.period == 0 {
        bail!("{what}.period must be positive");
    }
    if resolved.redundancy == 0 {
        bail!("{what}.redundancy must be positive");
    }
    match resolved.queue {
        // JackTrip itself rejects a non-positive -q (Settings.cpp), so this would not start.
        Queue::FixedMs { ms: 0 } => bail!("{what}.queue must not be 0 milliseconds"),
        Queue::FixedMs { ms } => {
            let floor = resolved.minimum_fixed_ms();
            if ms < floor {
                bail!(
                    "{what}.queue is {ms} ms of FIXED tolerance, below the {floor} ms that two \
                     periods of {} frames at {} Hz occupy -- under bufstrategy 3 this number is \
                     milliseconds, not packets, and adaptation is off, so it cannot absorb one \
                     late packet. Use \"auto\" unless you have measured this link.",
                    resolved.period,
                    resolved.sample_rate
                );
            }
        }
        Queue::AutoHeadroom { headroom_ms } if headroom_ms > 500 => {
            bail!("{what}.queue seeds {headroom_ms} ms of headroom, past JackTrip's 250 ms cap");
        }
        Queue::Auto | Queue::AutoHeadroom { .. } => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> Config {
        Config {
            node: "alpha".into(),
            control: ControlConfig::default(),
            transport: TransportConfig::default(),
            peers: BTreeMap::from([(
                "beta".into(),
                PeerConfig {
                    addresses: vec!["beta.local".into(), "198.51.100.2".into()],
                    control_port: 45900,
                    audio_port: 46001,
                    transport: PeerTransport::default(),
                },
            )]),
            catalogue: BTreeMap::new(),
        }
    }

    #[test]
    fn validates_clean_circle_config() {
        config().validate().unwrap();
    }

    #[test]
    fn rejects_self_peer_and_empty_command() {
        let mut value = config();
        value.peers.insert(
            "alpha".into(),
            PeerConfig {
                addresses: vec!["localhost".into()],
                control_port: 45900,
                audio_port: 46002,
                transport: PeerTransport::default(),
            },
        );
        assert!(value
            .validate()
            .unwrap_err()
            .to_string()
            .contains("must not"));
        value.peers.remove("alpha");
        value.transport.command.clear();
        assert!(value
            .validate()
            .unwrap_err()
            .to_string()
            .contains("transport.command"));
    }

    /// The wire form is JackTrip's own spelling, so what a config says, what a Nix option says and
    /// what a human types on a command line are the same three characters.
    #[test]
    fn queue_round_trips_through_its_wire_string() {
        for (text, queue) in [
            ("auto", Queue::Auto),
            ("auto12", Queue::AutoHeadroom { headroom_ms: 12 }),
            ("20", Queue::FixedMs { ms: 20 }),
        ] {
            assert_eq!(text.parse::<Queue>().unwrap(), queue);
            assert_eq!(queue.argument(), text);
            assert_eq!(
                serde_json::from_str::<Queue>(&format!("\"{text}\"")).unwrap(),
                queue
            );
            assert_eq!(serde_json::to_string(&queue).unwrap(), format!("\"{text}\""));
        }
        assert!("auto-3".parse::<Queue>().is_err());
        assert!("sometimes".parse::<Queue>().is_err());
    }

    /// A config written before `queue` carried its unit said `4` and meant packets; JackTrip read
    /// it as milliseconds either way. Reading the legacy number as what JackTrip actually did with
    /// it is the only migration that does not silently change a running link.
    #[test]
    fn a_legacy_numeric_queue_is_read_as_milliseconds() {
        assert_eq!(
            serde_json::from_str::<Queue>("20").unwrap(),
            Queue::FixedMs { ms: 20 }
        );
    }

    /// The bug this type exists to make unsayable: 4 ms is below two 128-frame periods at 48 kHz,
    /// and under bufstrategy 3 it is fixed, so it cannot absorb a single late packet.
    #[test]
    fn a_fixed_queue_below_two_periods_is_rejected() {
        let mut value = config();
        value.transport.queue = Queue::FixedMs { ms: 4 };
        let error = value.validate().unwrap_err().to_string();
        assert!(error.contains("below the 6 ms"), "{error}");
        value.transport.queue = Queue::FixedMs { ms: 6 };
        value.validate().unwrap();
    }

    /// A period is a per-link property, so the floor moves with the peer that overrode it.
    #[test]
    fn a_peer_overrides_the_hosts_transport_defaults() {
        let mut value = config();
        value.transport.period = 128;
        value.peers.get_mut("beta").unwrap().transport = PeerTransport {
            period: Some(64),
            queue: Some(Queue::FixedMs { ms: 3 }),
            ..PeerTransport::default()
        };
        let resolved = value.transport_for("beta");
        assert_eq!(resolved.period, 64);
        assert_eq!(resolved.bit_resolution, 16, "unset fields keep the default");
        assert_eq!(resolved.minimum_fixed_ms(), 3);
        value.validate().unwrap();

        value.peers.get_mut("beta").unwrap().transport.period = Some(256);
        let error = value.validate().unwrap_err().to_string();
        assert!(error.contains("peer beta transport.queue"), "{error}");
    }
}
