use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
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

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransportConfig {
    /// Command prefix used to launch JackTrip. The final element is the JackTrip executable.
    /// NixOS normally emits [".../pw-jack", ".../jacktrip"], while a foreign distribution can
    /// use its native pw-jack wrapper with the same Nix-built JackTrip binary.
    #[serde(default = "default_command")]
    pub command: Vec<String>,
    #[serde(default = "default_sample_rate")]
    pub sample_rate: u32,
    #[serde(default = "default_period")]
    pub period: u32,
    #[serde(default = "default_bit_resolution")]
    pub bit_resolution: u8,
    #[serde(default = "default_queue")]
    pub queue: u32,
    #[serde(default = "default_redundancy")]
    pub redundancy: u8,
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

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerConfig {
    /// Ordered candidates. The first answering control endpoint also carries the JackTrip client.
    pub addresses: Vec<String>,
    #[serde(default = "default_control_port")]
    pub control_port: u16,
    /// One UDP port per unordered peer pair. Both ends declare the same value.
    pub audio_port: u16,
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
fn default_queue() -> u32 {
    4
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
        if !matches!(self.transport.bit_resolution, 8 | 16 | 24 | 32) {
            bail!("transport.bitResolution must be 8, 16, 24 or 32");
        }
        if self.transport.period == 0 || self.transport.sample_rate == 0 {
            bail!("transport period and sample rate must be positive");
        }
        if self.transport.redundancy == 0 {
            bail!("transport.redundancy must be positive");
        }
        if self.transport.queue < 2 {
            bail!("transport.queue must be at least 2 packets");
        }
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
        }
        Ok(())
    }
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
}
