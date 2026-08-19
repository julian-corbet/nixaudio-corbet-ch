use crate::{
    config::Config,
    fabric::{EndpointManifest, Manifest, Snapshot as FabricSnapshot},
    state::State,
    API_VERSION,
};
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
    pub pipewire_id: Option<u32>,
    pub pipewire_name: Option<String>,
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
    media_name: String,
    media_class: String,
    application: String,
    application_id: String,
    media_role: String,
    carrier: Option<String>,
    profile: Option<String>,
    volume: f64,
    muted: bool,
}

#[derive(Clone, Debug)]
struct Port {
    id: u32,
    node: u32,
    name: String,
    direction: String,
    channel: String,
}

#[derive(Clone, Debug)]
struct Link {
    output_node: u32,
    output_port: u32,
    input_port: u32,
}

#[derive(Clone, Debug)]
pub struct Graph {
    pub snapshot: Snapshot,
    stream_nodes: HashMap<String, u32>,
    endpoint_nodes: HashMap<String, u32>,
    endpoint_ports: HashMap<String, Vec<u32>>,
    stream_intents: HashMap<String, String>,
    ports: Vec<Port>,
    links: Vec<Link>,
    actual_default_output: Option<String>,
    actual_default_input: Option<String>,
    fabric: FabricSnapshot,
    node_names: HashMap<String, u32>,
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

fn endpoint_identity(node: &Node) -> (String, String, String) {
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

fn numbered_port(name: &str, prefix: &str) -> Option<usize> {
    name.strip_prefix(prefix)?.parse().ok()
}

fn remote_id(peer: &str, local_id: &str) -> String {
    format!(
        "{}.{}",
        safe(peer),
        local_id.strip_prefix("local.").unwrap_or(local_id)
    )
}

impl Graph {
    pub fn inspect(
        config: &Config,
        state: &State,
        fabric: &FabricSnapshot,
        revision: u64,
    ) -> Result<Self> {
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
        Self::from_values(&values, config, state, fabric, revision)
    }

    pub fn from_values(
        values: &[Value],
        config: &Config,
        state: &State,
        fabric: &FabricSnapshot,
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
                                let value = text(props, "node.description");
                                if value.is_empty() {
                                    text(props, "node.name")
                                } else {
                                    value
                                }
                            },
                            media_name: text(props, "media.name"),
                            media_class: text(props, "media.class"),
                            application: {
                                let value = text(props, "application.name");
                                if value.is_empty() {
                                    text(props, "application.process.binary")
                                } else {
                                    value
                                }
                            },
                            application_id: {
                                let value = text(props, "application.id");
                                if value.is_empty() {
                                    text(props, "application.process.binary")
                                } else {
                                    value
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
                            volume,
                            muted,
                        },
                    );
                }
                "PipeWire:Interface:Port" => ports.push(Port {
                    id,
                    node: integer(props, "node.id") as u32,
                    name: text(props, "port.name"),
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
        let mut endpoint_ports = HashMap::new();
        let mut node_endpoints = HashMap::new();
        for node in nodes
            .values()
            .filter(|node| matches!(node.media_class.as_str(), "Audio/Sink" | "Audio/Source"))
        {
            let (mut id, device, label) = endpoint_identity(node);
            if endpoint_nodes.contains_key(&id) {
                id = format!("{}.{}", id, node.serial);
            }
            let wanted_direction = if node.media_class == "Audio/Sink" {
                "in"
            } else {
                "out"
            };
            let mut routable: Vec<&Port> = ports
                .iter()
                .filter(|port| port.node == node.id && port.direction == wanted_direction)
                .collect();
            routable.sort_by(|a, b| a.channel.cmp(&b.channel).then(a.id.cmp(&b.id)));
            endpoint_ports.insert(id.clone(), routable.iter().map(|port| port.id).collect());
            let endpoint = Endpoint {
                id: id.clone(),
                device,
                location: "local".into(),
                label,
                available: true,
                volume: node.volume,
                muted: node.muted,
                pipewire_id: Some(node.id),
                pipewire_name: Some(node.name.clone()),
            };
            endpoint_nodes.insert(id.clone(), node.id);
            node_endpoints.insert(node.id, id);
            if node.media_class == "Audio/Sink" {
                outputs.push(endpoint)
            } else {
                inputs.push(endpoint)
            }
        }

        // A remote output is a channel slice on one JackTrip node, not a fake PulseAudio sink.
        // It remains a first-class target in the nixaudio API because endpoint_ports points at the
        // exact JackTrip send ports that cross the host boundary.
        for (peer, remote) in &fabric.peers {
            let jacktrip = nodes
                .values()
                .find(|node| node.name == remote.plan.node_name);
            let mut send_ports: Vec<&Port> = jacktrip
                .map(|node| {
                    ports
                        .iter()
                        .filter(|port| {
                            port.node == node.id
                                && port.direction == "in"
                                && numbered_port(&port.name, "send_").is_some()
                        })
                        .collect()
                })
                .unwrap_or_default();
            send_ports.sort_by_key(|port| numbered_port(&port.name, "send_").unwrap_or(usize::MAX));
            for slice in &remote.plan.send {
                let Some(manifest) = remote
                    .manifest
                    .outputs
                    .iter()
                    .find(|endpoint| endpoint.id == slice.endpoint)
                else {
                    continue;
                };
                let first = slice.first - 1;
                let last = first + slice.channels.len();
                let target_ports = send_ports
                    .get(first..last)
                    .unwrap_or_default()
                    .iter()
                    .map(|port| port.id)
                    .collect::<Vec<_>>();
                let id = remote_id(peer, &manifest.id);
                endpoint_ports.insert(id.clone(), target_ports.clone());
                outputs.push(Endpoint {
                    id,
                    device: manifest
                        .id
                        .strip_prefix("local.")
                        .unwrap_or(&manifest.id)
                        .into(),
                    location: peer.clone(),
                    label: format!("{} · {}", peer, manifest.label),
                    // BOTH halves, and the conjunction is the point. The port count is a
                    // media-plane fact about OUR process; `remote.available` is a control-plane
                    // fact about THEIRS. Ports outlive the peer -- they vanish only when JackTrip
                    // itself exits, ten seconds after media stops -- so port count alone reports a
                    // dead destination as usable, which is how every endpoint on this fleet read
                    // `available: true` while nothing had ever carried a packet.
                    available: remote.available
                        && target_ports.len() == slice.channels.len(),
                    volume: 1.0,
                    muted: false,
                    pipewire_id: jacktrip.map(|node| node.id),
                    pipewire_name: jacktrip.map(|node| node.name.clone()),
                });
            }
        }
        outputs.sort_by(|a, b| a.id.cmp(&b.id));
        inputs.sort_by(|a, b| a.id.cmp(&b.id));

        let target_by_port: HashMap<u32, String> = endpoint_ports
            .iter()
            .flat_map(|(endpoint, ports)| {
                ports
                    .iter()
                    .map(|port| (*port, endpoint.clone()))
                    .collect::<Vec<_>>()
            })
            .collect();
        let mut stream_nodes = HashMap::new();
        let mut stream_intents = HashMap::new();
        let mut streams = Vec::new();
        for node in nodes
            .values()
            .filter(|node| node.media_class == "Stream/Output/Audio")
        {
            if node.name.starts_with("nixaudio") || node.name == "PipeWire" {
                continue;
            }
            let id = format!("stream:{}", node.serial);
            let app_key = if node.application_id.is_empty() {
                &node.application
            } else {
                &node.application_id
            };
            // Keyed on who is playing and in what capacity -- never on `media.name`, which is the
            // per-track title ("Pink Floyd: Time" is PipeWire's own example for it). A route the
            // user pinned belongs to "Firefox - video", not to the video that was open at the time.
            let intent_key = format!("{}|{}", app_key, node.media_role);
            let targets: BTreeSet<String> = links
                .iter()
                .filter(|link| link.output_node == node.id)
                .filter_map(|link| target_by_port.get(&link.input_port).cloned())
                .collect();
            let explicit_targets = state.routes.get(&intent_key).cloned().unwrap_or_default();
            streams.push(Stream {
                id: id.clone(),
                intent_key: intent_key.clone(),
                application: if node.application.is_empty() {
                    "Unknown application".into()
                } else {
                    node.application.clone()
                },
                title: if node.media_name.is_empty() {
                    node.description.clone()
                } else {
                    node.media_name.clone()
                },
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

        let mut peers: Vec<Peer> = config
            .peers
            .iter()
            .map(|(name, configured)| {
                let current = fabric.peers.get(name);
                Peer {
                    name: name.clone(),
                    address: current
                        .map(|peer| peer.address.clone())
                        .or_else(|| configured.addresses.first().cloned())
                        .unwrap_or_default(),
                    // "Can sound go there right now" -- the peer answers AND we hold a session
                    // for it. Either half alone is a half-truth a user would act on.
                    available: current.is_some_and(|peer| {
                        peer.available
                            && nodes.values().any(|node| node.name == peer.plan.node_name)
                    }),
                }
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
        // A DECLARED LOCAL DEVICE THAT IS NOT PLUGGED IN HERE IS NOT A FAULT, and counting it as one
        // is why this signal was useless. A device declaration is a naming rule: it says "if this
        // hardware appears, call it `hyperx`". The same declaration is deliberately made on every
        // host the hardware can roam to, because the name has to follow the device. So a headset
        // sitting in one machine's USB port left the other two permanently degraded, over hardware
        // they could play into perfectly well through their peers -- a status that is always red
        // says exactly as little as one that is always green.
        //
        // The absence is still published, in `unavailable_devices`, where a UI can show it as what
        // it is: something declared that is not here. Health does not have to claim it is wrong.
        let unavailable_peers = peers.iter().filter(|peer| !peer.available).count();
        let health =
            if outputs.iter().all(|endpoint| endpoint.location != "local") && inputs.is_empty() {
                Health {
                    status: "error".into(),
                    message: "PipeWire has no local audio devices".into(),
                }
            } else if unavailable_peers > 0 {
                Health {
                    status: "degraded".into(),
                    message: format!("{unavailable_peers} peer(s) cannot carry audio"),
                }
            } else {
                Health {
                    status: "ok".into(),
                    message: format!(
                        "{} output(s), {} input(s), {} peer(s)",
                        outputs.len(),
                        inputs.len(),
                        peers.len()
                    ),
                }
            };

        let actual_default_output = default_sink_name.and_then(|name| {
            outputs
                .iter()
                .find(|endpoint| endpoint.pipewire_name.as_deref() == Some(name.as_str()))
                .map(|endpoint| endpoint.id.clone())
        });
        let actual_default_input = default_source_name.and_then(|name| {
            inputs
                .iter()
                .find(|endpoint| endpoint.pipewire_name.as_deref() == Some(name.as_str()))
                .map(|endpoint| endpoint.id.clone())
        });
        // Remembered intent survives an outage, but the effective default must remain usable. A
        // remote default therefore falls back to PipeWire's local default while its peer is down
        // and automatically wins again when the same semantic endpoint returns.
        let default_output = state
            .default_output
            .clone()
            .filter(|wanted| {
                outputs
                    .iter()
                    .any(|endpoint| endpoint.id == *wanted && endpoint.available)
            })
            .or_else(|| actual_default_output.clone())
            .or_else(|| {
                outputs
                    .iter()
                    .find(|endpoint| endpoint.location == "local" && endpoint.available)
                    .map(|endpoint| endpoint.id.clone())
            });
        let default_input = state
            .default_input
            .clone()
            .filter(|wanted| {
                inputs
                    .iter()
                    .any(|endpoint| endpoint.id == *wanted && endpoint.available)
            })
            .or_else(|| actual_default_input.clone())
            .or_else(|| {
                inputs
                    .iter()
                    .find(|endpoint| endpoint.available)
                    .map(|endpoint| endpoint.id.clone())
            });
        let node_names = nodes
            .values()
            .map(|node| (node.name.clone(), node.id))
            .collect();
        let snapshot = Snapshot {
            api_version: API_VERSION,
            revision,
            host: config.node.clone(),
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
            endpoint_ports,
            stream_intents,
            ports,
            links,
            actual_default_output,
            actual_default_input,
            fabric: fabric.clone(),
            node_names,
        })
    }

    pub fn local_manifest(&self) -> Manifest {
        let mut manifest = Manifest {
            protocol: 1,
            node: self.snapshot.host.clone(),
            revision: self.snapshot.revision,
            outputs: Vec::new(),
            inputs: Vec::new(),
        };
        for (endpoints, public) in [
            (&self.snapshot.outputs, &mut manifest.outputs),
            (&self.snapshot.inputs, &mut manifest.inputs),
        ] {
            for endpoint in endpoints
                .iter()
                .filter(|endpoint| endpoint.location == "local")
            {
                let mut endpoint_ports: Vec<&Port> = self
                    .endpoint_ports
                    .get(&endpoint.id)
                    .into_iter()
                    .flatten()
                    .filter_map(|id| self.ports.iter().find(|port| port.id == *id))
                    .collect();
                endpoint_ports.sort_by(|a, b| a.channel.cmp(&b.channel).then(a.id.cmp(&b.id)));
                if endpoint_ports.is_empty() {
                    continue;
                }
                public.push(EndpointManifest {
                    id: endpoint.id.clone(),
                    label: endpoint.label.clone(),
                    channels: endpoint_ports
                        .iter()
                        .map(|port| port.channel.clone())
                        .collect(),
                });
            }
            public.sort_by(|a, b| a.id.cmp(&b.id));
        }
        manifest
    }

    pub fn reconcile_transport(&self) -> Result<()> {
        for peer in self.fabric.peers.values() {
            let Some(node) = self.node_names.get(&peer.plan.node_name).copied() else {
                continue;
            };
            let mut receive_ports: Vec<&Port> = self
                .ports
                .iter()
                .filter(|port| {
                    port.node == node
                        && port.direction == "out"
                        && numbered_port(&port.name, "receive_").is_some()
                })
                .collect();
            receive_ports
                .sort_by_key(|port| numbered_port(&port.name, "receive_").unwrap_or(usize::MAX));
            for slice in &peer.plan.receive {
                let Some(targets) = self.endpoint_ports.get(&slice.endpoint) else {
                    continue;
                };
                let first = slice.first - 1;
                for (index, target) in targets.iter().enumerate() {
                    let Some(source) = receive_ports.get(first + index) else {
                        continue;
                    };
                    if !self
                        .links
                        .iter()
                        .any(|link| link.output_port == source.id && link.input_port == *target)
                    {
                        run("pw-link", &[&source.id.to_string(), &target.to_string()])?;
                    }
                }
            }
        }
        Ok(())
    }

    pub fn stream_intent(&self, stream: &str) -> Result<&str> {
        self.stream_intents
            .get(stream)
            .map(String::as_str)
            .ok_or_else(|| anyhow!("unknown stream {stream}"))
    }

    /// Turn remembered intent into the destinations sound can actually reach right now.
    ///
    /// This is the whole of route fallback and route reclaim, and it is deliberately one function
    /// with no state of its own. Intent lives in `state.json` and is never rewritten here: the
    /// moment a fallback is written down it BECOMES the intent, and the route can never come back.
    ///
    /// Partial credit is on purpose. A stream pinned to two destinations with one of them away
    /// keeps the survivor and does not also gain the default, which would double-route it.
    /// Everything terminates: the default output has already been filtered to something available
    /// and local, so the recursion is one step deep by construction.
    pub fn resolve(&self, wanted: &[String]) -> Vec<String> {
        let live: Vec<String> = wanted
            .iter()
            .filter(|id| self.is_usable(id))
            .cloned()
            .collect();
        if !live.is_empty() {
            return live;
        }
        // Losing a peer must never mean losing the sound. Somewhere audible here is the answer.
        self.snapshot.default_output.clone().into_iter().collect()
    }

    /// Whether an endpoint can carry audio at this instant. One definition, so a route, a default
    /// and the tray cannot disagree about what "available" means.
    pub fn is_usable(&self, endpoint: &str) -> bool {
        self.snapshot
            .outputs
            .iter()
            .any(|candidate| candidate.id == endpoint && candidate.available)
            && self
                .endpoint_ports
                .get(endpoint)
                .is_some_and(|ports| !ports.is_empty())
    }

    /// Whether this id names something the user is ALLOWED to pin to -- a local endpoint that
    /// exists, or any endpoint on a configured peer. Deliberately weaker than `is_usable`: pinning
    /// to a peer that is currently asleep has to be legal, or intent could never outlive an outage.
    pub fn is_addressable(&self, config: &Config, endpoint: &str) -> bool {
        if self.endpoint_ports.contains_key(endpoint) {
            return true;
        }
        endpoint
            .split_once('.')
            .is_some_and(|(location, _)| config.peers.contains_key(location))
    }

    pub fn has_endpoint(&self, endpoint: &str) -> bool {
        self.endpoint_ports
            .get(endpoint)
            .is_some_and(|ports| !ports.is_empty())
    }

    pub fn stream_node(&self, stream: &str) -> Result<u32> {
        self.stream_nodes
            .get(stream)
            .copied()
            .ok_or_else(|| anyhow!("unknown stream {stream}"))
    }

    pub fn apply_route(&self, stream: &str, targets: &[String]) -> Result<()> {
        let stream_node = self.stream_node(stream)?;
        let all_target_ports: BTreeSet<u32> =
            self.endpoint_ports.values().flatten().copied().collect();
        for link in self.links.iter().filter(|link| {
            link.output_node == stream_node && all_target_ports.contains(&link.input_port)
        }) {
            run(
                "pw-link",
                &[
                    "-d",
                    &link.output_port.to_string(),
                    &link.input_port.to_string(),
                ],
            )?;
        }
        let mut source_ports: Vec<&Port> = self
            .ports
            .iter()
            .filter(|port| port.node == stream_node && port.direction == "out")
            .collect();
        source_ports.sort_by(|a, b| a.channel.cmp(&b.channel).then(a.id.cmp(&b.id)));
        for target in targets {
            let ids = self
                .endpoint_ports
                .get(target)
                .filter(|ports| !ports.is_empty())
                .ok_or_else(|| anyhow!("unknown or unavailable endpoint {target}"))?;
            let target_ports: Vec<&Port> = ids
                .iter()
                .filter_map(|id| self.ports.iter().find(|port| port.id == *id))
                .collect();
            if source_ports.is_empty() || target_ports.is_empty() {
                bail!("route ports are unavailable for {stream} -> {target}");
            }
            for (index, source) in source_ports.iter().enumerate() {
                let sink = target_ports
                    .iter()
                    .find(|port| !source.channel.is_empty() && port.channel == source.channel)
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
            .filter(|target| self.endpoint_nodes.contains_key(*target))
        {
            if self.actual_default_output.as_deref() != Some(target) {
                self.set_default(target)?;
            }
        }
        if let Some(target) = state
            .default_input
            .as_deref()
            .filter(|target| self.endpoint_nodes.contains_key(*target))
        {
            if self.actual_default_input.as_deref() != Some(target) {
                self.set_default(target)?;
            }
        }
        Ok(())
    }

    pub fn set_default(&self, endpoint: &str) -> Result<()> {
        let Some(node) = self.endpoint_nodes.get(endpoint) else {
            // A remote default is implemented by routing every unpinned stream to its JackTrip
            // channel slice. There is deliberately no fake local sink for wpctl to select.
            if self.has_endpoint(endpoint) {
                return Ok(());
            }
            bail!("unknown or unavailable endpoint {endpoint}");
        };
        run("wpctl", &["set-default", &node.to_string()])
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
            .ok_or_else(|| {
                anyhow!("remote endpoint level control is not available for {object}")
            })?;
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
            .ok_or_else(|| anyhow!("remote endpoint mute control is not available for {object}"))?;
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
    use crate::{
        config::{ControlConfig, PeerConfig, TransportConfig},
        fabric::{ChannelSlice, Manifest, PeerSnapshot, Role, SessionPlan},
    };
    use serde_json::json;
    use std::collections::{BTreeMap, BTreeSet};

    fn config() -> Config {
        Config {
            node: "alpha".into(),
            control: ControlConfig::default(),
            transport: TransportConfig::default(),
            peers: BTreeMap::new(),
            catalogue: BTreeMap::new(),
        }
    }

    fn port(id: u32, node: u32, name: &str, direction: &str, channel: &str) -> Value {
        json!({"id": id, "type": "PipeWire:Interface:Port", "info": {"props": {
            "node.id": node, "port.name": name, "port.direction": direction, "audio.channel": channel
        }}})
    }

    #[test]
    fn sanitizes_semantic_identifiers() {
        assert_eq!(safe("HyperX Cloud III S"), "hyperx_cloud_iii_s");
        assert_eq!(safe("alsa_output.usb-1"), "alsa_output_usb-1");
    }

    #[test]
    fn joins_stream_links_to_stable_endpoints() {
        let values = vec![
            json!({"id": 10, "type": "PipeWire:Interface:Node", "info": {"props": {
                "object.serial": 100, "node.name": "alsa_output.usb-hyperx", "node.description": "HyperX",
                "media.class": "Audio/Sink", "alsa.nixaudio.device": "hyperx", "device.profile.name": "analog-stereo"
            }}}),
            port(11, 10, "playback_FL", "in", "FL"),
            port(12, 10, "playback_FR", "in", "FR"),
            json!({"id": 20, "type": "PipeWire:Interface:Node", "info": {"props": {
                "object.serial": 200, "node.name": "Firefox", "media.name": "A useful tab",
                "media.class": "Stream/Output/Audio", "application.name": "Firefox", "application.process.binary": "firefox"
            }}}),
            port(21, 20, "output_FL", "out", "FL"),
            json!({"id": 30, "type": "PipeWire:Interface:Link", "info": {
                "output-node-id": 20, "output-port-id": 21, "input-node-id": 10, "input-port-id": 11
            }}),
            json!({"id": 40, "type": "PipeWire:Interface:Metadata", "metadata": [{
                "key": "default.audio.sink", "value": {"name": "alsa_output.usb-hyperx"}
            }]}),
        ];
        let state = State {
            default_output: Some("beta.unavailable".into()),
            ..State::default()
        };
        let graph =
            Graph::from_values(&values, &config(), &state, &FabricSnapshot::default(), 7).unwrap();
        assert_eq!(graph.snapshot.outputs[0].id, "local.hyperx.analog-stereo");
        assert_eq!(
            graph.snapshot.default_output.as_deref(),
            Some("local.hyperx.analog-stereo")
        );
        assert_eq!(graph.snapshot.streams[0].title, "A useful tab");
        assert_eq!(
            graph.snapshot.streams[0].targets,
            ["local.hyperx.analog-stereo"]
        );
        assert_eq!(graph.local_manifest().outputs[0].channels, ["FL", "FR"]);
    }

    #[test]
    fn jacktrip_channel_slice_is_a_remote_pipewire_target() {
        let mut cfg = config();
        cfg.peers.insert(
            "beta".into(),
            PeerConfig {
                addresses: vec!["beta.local".into()],
                control_port: 45900,
                audio_port: 46001,
                transport: crate::config::PeerTransport::default(),
            },
        );
        let manifest = Manifest {
            protocol: 1,
            node: "beta".into(),
            revision: 2,
            outputs: vec![EndpointManifest {
                id: "local.hyperx".into(),
                label: "HyperX".into(),
                channels: vec!["FL".into(), "FR".into()],
            }],
            inputs: Vec::new(),
        };
        let plan = SessionPlan {
            peer: "beta".into(),
            address: "beta.local".into(),
            audio_port: 46001,
            node_name: "nixaudio-jt-beta".into(),
            role: Role::Server,
            send: vec![ChannelSlice {
                endpoint: "local.hyperx".into(),
                first: 1,
                channels: vec!["FL".into(), "FR".into()],
            }],
            receive: Vec::new(),
            send_channels: 2,
            receive_channels: 1,
        };
        let fabric = FabricSnapshot {
            peers: BTreeMap::from([(
                "beta".into(),
                PeerSnapshot {
                    address: "beta.local".into(),
                    manifest,
                    plan,
                    available: true,
                    misses: 0,
                },
            )]),
        };
        let values = vec![
            json!({"id": 50, "type": "PipeWire:Interface:Node", "info": {"props": {
                "object.serial": 500, "node.name": "nixaudio-jt-beta", "node.description": "nixaudio-jt-beta"
            }}}),
            port(51, 50, "send_1", "in", "FL"),
            port(52, 50, "send_2", "in", "FR"),
            json!({"id": 20, "type": "PipeWire:Interface:Node", "info": {"props": {
                "object.serial": 200, "node.name": "Firefox", "media.name": "Music",
                "media.class": "Stream/Output/Audio", "application.name": "Firefox"
            }}}),
            port(21, 20, "output_FL", "out", "FL"),
            json!({"id": 30, "type": "PipeWire:Interface:Link", "info": {
                "output-node-id": 20, "output-port-id": 21, "input-node-id": 50, "input-port-id": 51
            }}),
        ];
        let graph = Graph::from_values(&values, &cfg, &State::default(), &fabric, 3).unwrap();
        let output = graph
            .snapshot
            .outputs
            .iter()
            .find(|endpoint| endpoint.id == "beta.hyperx")
            .unwrap();
        assert!(output.available);
        assert_eq!(graph.snapshot.streams[0].targets, ["beta.hyperx"]);
    }

    /// `media.name` is PipeWire's per-track title -- its own keys.h offers "Pink Floyd: Time" as
    /// the example. A remembered route keyed on it stops matching at the next track, and because an
    /// empty explicit target set falls back to the default output, the stream is actively dragged
    /// off the device the user pinned it to, mid-playback. The route belongs to the application and
    /// its role, which is exactly what the tray shows: "Firefox - video".
    #[test]
    fn a_remembered_route_survives_a_change_of_track() {
        let playing = |title: &str| {
            vec![
                json!({"id": 10, "type": "PipeWire:Interface:Node", "info": {"props": {
                    "object.serial": 100, "node.name": "alsa_output.usb-hyperx",
                    "node.description": "HyperX", "media.class": "Audio/Sink",
                    "alsa.nixaudio.device": "hyperx", "device.profile.name": "analog-stereo"
                }}}),
                port(11, 10, "playback_FL", "in", "FL"),
                port(12, 10, "playback_FR", "in", "FR"),
                json!({"id": 20, "type": "PipeWire:Interface:Node", "info": {"props": {
                    "object.serial": 200, "node.name": "Firefox", "media.name": title,
                    "media.class": "Stream/Output/Audio", "application.name": "Firefox",
                    "application.process.binary": "firefox", "media.role": "Music"
                }}}),
                port(21, 20, "output_FL", "out", "FL"),
            ]
        };

        let first = Graph::from_values(
            &playing("Pink Floyd: Time"),
            &config(),
            &State::default(),
            &FabricSnapshot::default(),
            1,
        )
        .unwrap();
        let pinned = first.snapshot.streams[0].intent_key.clone();

        let mut state = State::default();
        state.routes.insert(
            pinned,
            BTreeSet::from(["local.hyperx.analog-stereo".into()]),
        );

        let next = Graph::from_values(
            &playing("Pink Floyd: Money"),
            &config(),
            &state,
            &FabricSnapshot::default(),
            2,
        )
        .unwrap();
        assert_eq!(
            next.snapshot.streams[0].explicit_targets,
            ["local.hyperx.analog-stereo"],
            "the route was pinned to the application, not to the track that happened to be playing"
        );
    }
}
