use crate::{config::Config, state::State, API_VERSION};
use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeSet, HashMap},
    process::Command,
};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Snapshot {
    pub api_version: u32,
    pub revision: u64,
    pub host: String,
    pub health: Health,
    pub outputs: Vec<Endpoint>,
    pub inputs: Vec<Endpoint>,
    pub streams: Vec<Stream>,
    pub peers: Vec<Peer>,
    pub unavailable_devices: Vec<DeclaredDevice>,
    pub default_output: Option<String>,
    pub default_input: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Health {
    pub status: String,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Endpoint {
    pub id: String,
    pub device: String,
    pub location: String,
    pub label: String,
    pub available: bool,
    pub volume: f64,
    pub muted: bool,
    pub pipewire_id: u32,
    pub pipewire_name: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Stream {
    pub id: String,
    pub intent_key: String,
    pub application: String,
    pub title: String,
    pub volume: f64,
    pub muted: bool,
    pub targets: Vec<String>,
    pub explicit_targets: Vec<String>,
    pub pipewire_id: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Peer {
    pub name: String,
    pub address: String,
    pub available: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct DeclaredDevice {
    pub id: String,
    pub label: String,
    pub location: String,
}

#[derive(Clone, Debug)]
struct Node {
    id: u32,
    serial: u64,
    name: String,
    description: String,
    media_class: String,
    application: String,
    application_id: String,
    media_role: String,
    carrier: Option<String>,
    profile: Option<String>,
    peer: Option<String>,
    remote_device: Option<String>,
    volume: f64,
    muted: bool,
}

#[derive(Clone, Debug)]
struct Port {
    id: u32,
    node: u32,
    direction: String,
    channel: String,
}

#[derive(Clone, Debug)]
struct Link {
    output_node: u32,
    output_port: u32,
    input_node: u32,
    input_port: u32,
}

#[derive(Clone, Debug)]
pub struct Graph {
    pub snapshot: Snapshot,
    stream_nodes: HashMap<String, u32>,
    endpoint_nodes: HashMap<String, u32>,
    stream_intents: HashMap<String, String>,
    ports: Vec<Port>,
    links: Vec<Link>,
    actual_default_output: Option<String>,
    actual_default_input: Option<String>,
}

fn text(props: &Value, key: &str) -> String {
    props
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn integer(props: &Value, key: &str) -> u64 {
    props.get(key).and_then(Value::as_u64).unwrap_or_default()
}

fn volume_and_mute(info: &Value) -> (f64, bool) {
    let props = info
        .get("params")
        .and_then(|v| v.get("Props"))
        .and_then(Value::as_array)
        .and_then(|v| v.first());
    let volume = props
        .and_then(|v| v.get("volume"))
        .and_then(Value::as_f64)
        .or_else(|| {
            props
                .and_then(|v| v.get("channelVolumes"))
                .and_then(Value::as_array)
                .and_then(|v| v.first())
                .and_then(Value::as_f64)
        })
        .unwrap_or(1.0);
    let muted = props
        .and_then(|v| v.get("mute"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    (volume, muted)
}

fn safe(value: &str) -> String {
    let out: String = value
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect();
    out.trim_matches('_').to_lowercase()
}

fn tunnel_identity(node: &Node, config: &Config) -> Option<(String, String)> {
    if let (Some(peer), Some(device)) = (&node.peer, &node.remote_device) {
        return Some((peer.clone(), device.clone()));
    }
    let rest = node.description.strip_prefix("Tunnel to tcp:")?;
    let (server, device) = rest.split_once('/')?;
    let address = server.rsplit_once(':').map(|v| v.0).unwrap_or(server);
    let peer = config
        .peers
        .get(address)
        .cloned()
        .unwrap_or_else(|| address.to_owned());
    Some((peer, device.to_owned()))
}

fn endpoint_identity(node: &Node, config: &Config) -> (String, String, String) {
    if let Some((peer, raw_device)) = tunnel_identity(node, config) {
        let declared = config.catalogue.values().find(|entry| {
            entry.peer.as_deref() == Some(peer.as_str()) && entry.device == raw_device
        });
        let device = declared
            .map(|v| v.device.clone())
            .unwrap_or_else(|| safe(&raw_device));
        let label = declared
            .and_then(|v| v.description.clone())
            .or_else(|| {
                config
                    .catalogue
                    .values()
                    .find(|entry| entry.origin == "local" && entry.device == device)
                    .and_then(|entry| entry.description.clone())
            })
            .unwrap_or_else(|| node.description.clone());
        return (
            format!("{}.{}", safe(&peer), safe(&device)),
            device,
            format!("{} · {}", peer, label),
        );
    }
    let device = node.carrier.clone().unwrap_or_else(|| safe(&node.name));
    let suffix = node
        .profile
        .as_deref()
        .filter(|_| node.carrier.is_some())
        .map(safe);
    let id = match suffix {
        Some(profile) if !profile.is_empty() => format!("local.{}.{}", safe(&device), profile),
        _ => format!("local.{}", safe(&device)),
    };
    (id, device, node.description.clone())
}

impl Graph {
    pub fn inspect(config: &Config, state: &State, revision: u64) -> Result<Self> {
        let output = Command::new("timeout")
            .args(["--kill-after=1s", "6s", "pw-dump"])
            .output()
            .context("run pw-dump")?;
        if !output.status.success() {
            bail!(
                "pw-dump failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
        let values: Vec<Value> =
            serde_json::from_slice(&output.stdout).context("parse pw-dump output")?;
        Self::from_values(&values, config, state, revision)
    }

    pub fn from_values(
        values: &[Value],
        config: &Config,
        state: &State,
        revision: u64,
    ) -> Result<Self> {
        let mut nodes = HashMap::new();
        let mut ports = Vec::new();
        let mut links = Vec::new();
        let mut default_sink_name = None;
        let mut default_source_name = None;
        for value in values {
            let kind = value
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let id = value.get("id").and_then(Value::as_u64).unwrap_or_default() as u32;
            let info = value.get("info").unwrap_or(&Value::Null);
            let props = info.get("props").unwrap_or(&Value::Null);
            match kind {
                "PipeWire:Interface:Node" => {
                    let (volume, muted) = volume_and_mute(info);
                    nodes.insert(
                        id,
                        Node {
                            id,
                            serial: integer(props, "object.serial"),
                            name: text(props, "node.name"),
                            description: {
                                let v = text(props, "node.description");
                                if v.is_empty() {
                                    text(props, "node.name")
                                } else {
                                    v
                                }
                            },
                            media_class: text(props, "media.class"),
                            application: {
                                let v = text(props, "application.name");
                                if v.is_empty() {
                                    text(props, "application.process.binary")
                                } else {
                                    v
                                }
                            },
                            application_id: {
                                let v = text(props, "application.id");
                                if v.is_empty() {
                                    text(props, "application.process.binary")
                                } else {
                                    v
                                }
                            },
                            media_role: text(props, "media.role"),
                            carrier: props
                                .get("alsa.nixaudio.device")
                                .and_then(Value::as_str)
                                .map(ToOwned::to_owned),
                            profile: props
                                .get("device.profile.name")
                                .and_then(Value::as_str)
                                .map(ToOwned::to_owned),
                            peer: props
                                .get("nixaudio.peer")
                                .and_then(Value::as_str)
                                .map(ToOwned::to_owned),
                            remote_device: props
                                .get("nixaudio.device")
                                .and_then(Value::as_str)
                                .map(ToOwned::to_owned),
                            volume,
                            muted,
                        },
                    );
                }
                "PipeWire:Interface:Port" => ports.push(Port {
                    id,
                    node: integer(props, "node.id") as u32,
                    direction: text(props, "port.direction"),
                    channel: text(props, "audio.channel"),
                }),
                "PipeWire:Interface:Link" => links.push(Link {
                    output_node: info
                        .get("output-node-id")
                        .and_then(Value::as_u64)
                        .unwrap_or_default() as u32,
                    output_port: info
                        .get("output-port-id")
                        .and_then(Value::as_u64)
                        .unwrap_or_default() as u32,
                    input_node: info
                        .get("input-node-id")
                        .and_then(Value::as_u64)
                        .unwrap_or_default() as u32,
                    input_port: info
                        .get("input-port-id")
                        .and_then(Value::as_u64)
                        .unwrap_or_default() as u32,
                }),
                "PipeWire:Interface:Metadata" => {
                    if let Some(entries) = value.get("metadata").and_then(Value::as_array) {
                        for entry in entries {
                            let key = entry.get("key").and_then(Value::as_str);
                            let name = entry
                                .get("value")
                                .and_then(|v| v.get("name"))
                                .and_then(Value::as_str)
                                .map(ToOwned::to_owned);
                            match key {
                                Some("default.audio.sink") => default_sink_name = name,
                                Some("default.audio.source") => default_source_name = name,
                                _ => {}
                            }
                        }
                    }
                }
                _ => {}
            }
        }

        let mut outputs = Vec::new();
        let mut inputs = Vec::new();
        let mut endpoint_nodes = HashMap::new();
        let mut node_endpoints = HashMap::new();
        for node in nodes
            .values()
            .filter(|n| matches!(n.media_class.as_str(), "Audio/Sink" | "Audio/Source"))
        {
            let (mut id, device, label) = endpoint_identity(node, config);
            if endpoint_nodes.contains_key(&id) {
                id = format!("{}.{}", id, node.serial);
            }
            let location = tunnel_identity(node, config)
                .map(|v| v.0)
                .unwrap_or_else(|| "local".into());
            let endpoint = Endpoint {
                id: id.clone(),
                device,
                location,
                label,
                available: true,
                volume: node.volume,
                muted: node.muted,
                pipewire_id: node.id,
                pipewire_name: node.name.clone(),
            };
            endpoint_nodes.insert(id.clone(), node.id);
            node_endpoints.insert(node.id, id);
            if node.media_class == "Audio/Sink" {
                outputs.push(endpoint)
            } else {
                inputs.push(endpoint)
            }
        }
        outputs.sort_by(|a, b| a.id.cmp(&b.id));
        inputs.sort_by(|a, b| a.id.cmp(&b.id));

        let mut stream_nodes = HashMap::new();
        let mut stream_intents = HashMap::new();
        let mut streams = Vec::new();
        for node in nodes
            .values()
            .filter(|n| n.media_class == "Stream/Output/Audio")
        {
            if node.name.starts_with("nixaudio")
                || node.name == "PipeWire"
                || node.description.starts_with("Tunnel for ")
            {
                continue;
            }
            let id = format!("stream:{}", node.serial);
            let app_key = if node.application_id.is_empty() {
                &node.application
            } else {
                &node.application_id
            };
            let intent_key = format!("{}|{}|{}", app_key, node.media_role, node.name);
            let mut targets: BTreeSet<String> = links
                .iter()
                .filter(|l| l.output_node == node.id)
                .filter_map(|l| node_endpoints.get(&l.input_node).cloned())
                .collect();
            let explicit_targets = state.routes.get(&intent_key).cloned().unwrap_or_default();
            if targets.is_empty() {
                targets = explicit_targets.clone();
            }
            streams.push(Stream {
                id: id.clone(),
                intent_key: intent_key.clone(),
                application: if node.application.is_empty() {
                    "Unknown application".into()
                } else {
                    node.application.clone()
                },
                title: node.description.clone(),
                volume: node.volume,
                muted: node.muted,
                targets: targets.into_iter().collect(),
                explicit_targets: explicit_targets.into_iter().collect(),
                pipewire_id: node.id,
            });
            stream_nodes.insert(id.clone(), node.id);
            stream_intents.insert(id, intent_key);
        }
        streams.sort_by(|a, b| {
            a.application
                .cmp(&b.application)
                .then(a.title.cmp(&b.title))
        });

        let live_peers: BTreeSet<String> = outputs
            .iter()
            .chain(inputs.iter())
            .filter(|v| v.location != "local")
            .map(|v| v.location.clone())
            .collect();
        let mut peers: Vec<Peer> = config
            .peers
            .iter()
            .map(|(address, name)| Peer {
                name: name.clone(),
                address: address.clone(),
                available: live_peers.contains(name),
            })
            .collect();
        peers.sort_by(|a, b| a.name.cmp(&b.name));
        let mut unavailable_devices: Vec<DeclaredDevice> = config
            .catalogue
            .iter()
            .filter_map(|(id, entry)| {
                let location = entry.peer.clone().unwrap_or_else(|| "local".into());
                let live = outputs.iter().chain(inputs.iter()).any(|endpoint| {
                    endpoint.device == entry.device && endpoint.location == location
                });
                (!live).then(|| DeclaredDevice {
                    id: if entry.origin == "local" {
                        format!("local.{}", safe(id))
                    } else {
                        id.clone()
                    },
                    label: entry
                        .description
                        .clone()
                        .unwrap_or_else(|| entry.device.clone()),
                    location,
                })
            })
            .collect();
        unavailable_devices.sort_by(|a, b| a.id.cmp(&b.id));
        let missing = config
            .catalogue
            .iter()
            .filter(|(_, v)| v.origin == "local")
            .filter(|(key, _)| {
                !outputs
                    .iter()
                    .chain(inputs.iter())
                    .any(|endpoint| &endpoint.device == *key)
            })
            .count();
        let health = if outputs.is_empty() && inputs.is_empty() {
            Health {
                status: "error".into(),
                message: "PipeWire has no audio devices".into(),
            }
        } else if missing > 0 {
            Health {
                status: "degraded".into(),
                message: format!("{} declared local device(s) are unavailable", missing),
            }
        } else {
            Health {
                status: "ok".into(),
                message: format!("{} output(s), {} input(s)", outputs.len(), inputs.len()),
            }
        };
        let actual_default_output = default_sink_name.and_then(|name| {
            outputs
                .iter()
                .find(|v| v.pipewire_name == name)
                .map(|v| v.id.clone())
        });
        let actual_default_input = default_source_name.and_then(|name| {
            inputs
                .iter()
                .find(|v| v.pipewire_name == name)
                .map(|v| v.id.clone())
        });
        let default_output = state
            .default_output
            .clone()
            .or_else(|| actual_default_output.clone());
        let default_input = state
            .default_input
            .clone()
            .or_else(|| actual_default_input.clone());
        let host = hostname::get()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        let snapshot = Snapshot {
            api_version: API_VERSION,
            revision,
            host,
            health,
            outputs,
            inputs,
            streams,
            peers,
            unavailable_devices,
            default_output,
            default_input,
        };
        Ok(Self {
            snapshot,
            stream_nodes,
            endpoint_nodes,
            stream_intents,
            ports,
            links,
            actual_default_output,
            actual_default_input,
        })
    }

    pub fn stream_intent(&self, stream: &str) -> Result<&str> {
        self.stream_intents
            .get(stream)
            .map(String::as_str)
            .ok_or_else(|| anyhow!("unknown stream {stream}"))
    }
    pub fn has_endpoint(&self, endpoint: &str) -> bool {
        self.endpoint_nodes.contains_key(endpoint)
    }
    pub fn endpoint_node(&self, endpoint: &str) -> Result<u32> {
        self.endpoint_nodes
            .get(endpoint)
            .copied()
            .ok_or_else(|| anyhow!("unknown or unavailable endpoint {endpoint}"))
    }
    pub fn stream_node(&self, stream: &str) -> Result<u32> {
        self.stream_nodes
            .get(stream)
            .copied()
            .ok_or_else(|| anyhow!("unknown stream {stream}"))
    }

    pub fn apply_route(&self, stream: &str, targets: &[String]) -> Result<()> {
        let stream_node = self.stream_node(stream)?;
        let sink_nodes: BTreeSet<u32> = self
            .snapshot
            .outputs
            .iter()
            .map(|v| v.pipewire_id)
            .collect();
        for link in self
            .links
            .iter()
            .filter(|v| v.output_node == stream_node && sink_nodes.contains(&v.input_node))
        {
            run(
                "pw-link",
                &[
                    "-d",
                    &link.output_port.to_string(),
                    &link.input_port.to_string(),
                ],
            )?;
        }
        let source_ports: Vec<&Port> = self
            .ports
            .iter()
            .filter(|v| v.node == stream_node && v.direction == "out")
            .collect();
        for target in targets {
            let target_node = self.endpoint_node(target)?;
            let target_ports: Vec<&Port> = self
                .ports
                .iter()
                .filter(|v| v.node == target_node && v.direction == "in")
                .collect();
            if source_ports.is_empty() || target_ports.is_empty() {
                bail!("route ports are unavailable for {stream} -> {target}");
            }
            for (index, source) in source_ports.iter().enumerate() {
                let sink = target_ports
                    .iter()
                    .find(|v| !source.channel.is_empty() && v.channel == source.channel)
                    .copied()
                    .unwrap_or(target_ports[index.min(target_ports.len() - 1)]);
                run("pw-link", &[&source.id.to_string(), &sink.id.to_string()])?;
            }
        }
        Ok(())
    }

    pub fn restore_default_route(&self, stream: &str) -> Result<()> {
        let target = self
            .snapshot
            .default_output
            .as_deref()
            .ok_or_else(|| anyhow!("no default output is available"))?;
        self.apply_route(stream, &[target.to_owned()])
    }

    pub fn reconcile_defaults(&self, state: &State) -> Result<()> {
        if let Some(target) = state
            .default_output
            .as_deref()
            .filter(|target| self.has_endpoint(target))
        {
            if self.actual_default_output.as_deref() != Some(target) {
                self.set_default(target)?;
            }
        }
        if let Some(target) = state
            .default_input
            .as_deref()
            .filter(|target| self.has_endpoint(target))
        {
            if self.actual_default_input.as_deref() != Some(target) {
                self.set_default(target)?;
            }
        }
        Ok(())
    }

    pub fn set_default(&self, endpoint: &str) -> Result<()> {
        run(
            "wpctl",
            &["set-default", &self.endpoint_node(endpoint)?.to_string()],
        )
    }
    pub fn set_volume(&self, object: &str, volume: f64) -> Result<()> {
        if !(0.0..=1.5).contains(&volume) {
            bail!("volume must be between 0.0 and 1.5");
        }
        let node = self
            .stream_nodes
            .get(object)
            .or_else(|| self.endpoint_nodes.get(object))
            .copied()
            .ok_or_else(|| anyhow!("unknown object {object}"))?;
        run(
            "wpctl",
            &["set-volume", &node.to_string(), &format!("{volume:.3}")],
        )
    }
    pub fn set_muted(&self, object: &str, muted: bool) -> Result<()> {
        let node = self
            .stream_nodes
            .get(object)
            .or_else(|| self.endpoint_nodes.get(object))
            .copied()
            .ok_or_else(|| anyhow!("unknown object {object}"))?;
        run(
            "wpctl",
            &["set-mute", &node.to_string(), if muted { "1" } else { "0" }],
        )
    }
}

fn run(program: &str, arguments: &[&str]) -> Result<()> {
    let output = Command::new("timeout")
        .args(["--kill-after=1s", "6s", program])
        .args(arguments)
        .output()
        .with_context(|| format!("run {program}"))?;
    if output.status.success() {
        Ok(())
    } else {
        bail!(
            "{} {} failed: {}",
            program,
            arguments.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_semantic_identifiers() {
        assert_eq!(safe("HyperX Cloud III S"), "hyperx_cloud_iii_s");
        assert_eq!(safe("alsa_output.usb-1"), "alsa_output_usb-1");
    }
}
