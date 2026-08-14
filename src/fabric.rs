use crate::config::{Config, PeerConfig, TransportConfig};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    process::Stdio,
    sync::{Arc, RwLock},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    process::{Child, Command},
    time::timeout,
};

const CONTROL_GREETING: &str = "NXAUDIO/1 MANIFEST\n";
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;

/// The cross-host contract deliberately contains semantic identities and channel positions, never
/// PipeWire object IDs or port names. Those are meaningful only inside the publishing graph.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub protocol: u32,
    pub node: String,
    pub revision: u64,
    pub outputs: Vec<EndpointManifest>,
    pub inputs: Vec<EndpointManifest>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EndpointManifest {
    pub id: String,
    pub label: String,
    pub channels: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChannelSlice {
    pub endpoint: String,
    /// JackTrip channels are numbered from one in its PipeWire port names.
    pub first: usize,
    pub channels: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Role {
    Server,
    Client,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionPlan {
    pub peer: String,
    pub address: String,
    pub audio_port: u16,
    pub node_name: String,
    pub role: Role,
    /// Local audio sent to these peer outputs, in channel order.
    pub send: Vec<ChannelSlice>,
    /// Peer audio received for these local outputs, in channel order.
    pub receive: Vec<ChannelSlice>,
    pub send_channels: usize,
    pub receive_channels: usize,
}

#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub peers: BTreeMap<String, PeerSnapshot>,
}

#[derive(Clone, Debug)]
pub struct PeerSnapshot {
    pub address: String,
    pub manifest: Manifest,
    pub plan: SessionPlan,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct WorkerSpec {
    command: Vec<String>,
    arguments: Vec<String>,
    latency: String,
}

struct Worker {
    spec: WorkerSpec,
    child: Child,
}

#[derive(Default)]
pub struct Runtime {
    workers: BTreeMap<String, Worker>,
}

fn safe(value: &str) -> String {
    value
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_owned()
}

fn slices(endpoints: &[EndpointManifest]) -> Vec<ChannelSlice> {
    let mut endpoints = endpoints.to_vec();
    endpoints.sort_by(|a, b| a.id.cmp(&b.id));
    let mut next = 1;
    endpoints
        .into_iter()
        .map(|endpoint| {
            let first = next;
            next += endpoint.channels.len();
            ChannelSlice {
                endpoint: endpoint.id,
                first,
                channels: endpoint.channels,
            }
        })
        .collect()
}

fn validate_manifest(peer: &str, manifest: &Manifest) -> Result<()> {
    if manifest.protocol != 1 {
        bail!(
            "peer {peer} uses unsupported manifest protocol {}",
            manifest.protocol
        );
    }
    let mut ids = BTreeSet::new();
    for endpoint in manifest.outputs.iter().chain(&manifest.inputs) {
        if endpoint.id.is_empty() || endpoint.channels.is_empty() {
            bail!("peer {peer} announced an endpoint without an id or channels");
        }
        if !ids.insert(endpoint.id.as_str()) {
            bail!("peer {peer} announced duplicate endpoint {}", endpoint.id);
        }
    }
    Ok(())
}

pub fn plan(
    node: &str,
    peer: &str,
    address: &str,
    audio_port: u16,
    local: &Manifest,
    remote: &Manifest,
) -> Result<SessionPlan> {
    validate_manifest(peer, remote)?;
    if remote.node != peer {
        bail!(
            "peer identity mismatch: configured {peer}, control endpoint announced {}",
            remote.node
        );
    }
    let send = slices(&remote.outputs);
    let receive = slices(&local.outputs);
    let send_channels = send.iter().map(|v| v.channels.len()).sum::<usize>().max(1);
    let receive_channels = receive
        .iter()
        .map(|v| v.channels.len())
        .sum::<usize>()
        .max(1);
    Ok(SessionPlan {
        peer: peer.into(),
        address: address.into(),
        audio_port,
        node_name: format!("nixaudio-jt-{}", safe(peer)),
        role: if node < peer {
            Role::Server
        } else {
            Role::Client
        },
        send,
        receive,
        send_channels,
        receive_channels,
    })
}

fn arguments(plan: &SessionPlan, transport: &TransportConfig) -> Vec<String> {
    let mut args = match plan.role {
        Role::Server => vec!["--server".into()],
        Role::Client => vec!["--client".into(), plan.address.clone()],
    };
    args.extend([
        "--sendchannels".into(),
        plan.send_channels.to_string(),
        "--receivechannels".into(),
        plan.receive_channels.to_string(),
        "--bindport".into(),
        plan.audio_port.to_string(),
        "--peerport".into(),
        plan.audio_port.to_string(),
        "--clientname".into(),
        plan.node_name.clone(),
        "--nojackportsconnect".into(),
        "--srate".into(),
        transport.sample_rate.to_string(),
        "--bufsize".into(),
        transport.period.to_string(),
        "--bitres".into(),
        transport.bit_resolution.to_string(),
        "--queue".into(),
        transport.queue.to_string(),
        "--redundancy".into(),
        transport.redundancy.to_string(),
        "--zerounderrun".into(),
        "--bufstrategy".into(),
        "3".into(),
        "--udprt".into(),
        "--timeout".into(),
    ]);
    args
}

fn worker_spec(plan: &SessionPlan, transport: &TransportConfig) -> WorkerSpec {
    WorkerSpec {
        command: transport.command.clone(),
        arguments: arguments(plan, transport),
        latency: format!("{}/{}", transport.period, transport.sample_rate),
    }
}

fn spawn_worker(spec: &WorkerSpec) -> Result<Child> {
    let (program, prefix) = spec
        .command
        .split_first()
        .context("transport command is empty")?;
    let mut command = Command::new(program);
    command
        .args(prefix)
        .args(&spec.arguments)
        .env("PIPEWIRE_LATENCY", &spec.latency)
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .kill_on_drop(true);
    command
        .spawn()
        .with_context(|| format!("start JackTrip through {}", spec.command.join(" ")))
}

async fn fetch_at(address: &str, port: u16) -> Result<Manifest> {
    let mut stream = timeout(
        Duration::from_millis(900),
        TcpStream::connect((address, port)),
    )
    .await
    .context("control connect timed out")?
    .with_context(|| format!("connect to {address}:{port}"))?;
    stream.write_all(CONTROL_GREETING.as_bytes()).await?;
    stream.shutdown().await?;
    let mut bytes = Vec::new();
    timeout(
        Duration::from_millis(900),
        stream.take(MAX_MANIFEST_BYTES).read_to_end(&mut bytes),
    )
    .await
    .context("manifest read timed out")??;
    if bytes.len() as u64 == MAX_MANIFEST_BYTES {
        bail!("manifest exceeds {MAX_MANIFEST_BYTES} bytes");
    }
    serde_json::from_slice(&bytes).context("decode peer manifest")
}

async fn fetch(peer: &PeerConfig) -> Result<(String, Manifest)> {
    let mut errors = Vec::new();
    for address in &peer.addresses {
        match fetch_at(address, peer.control_port).await {
            Ok(manifest) => return Ok((address.clone(), manifest)),
            Err(error) => errors.push(format!("{address}: {error:#}")),
        }
    }
    bail!("no peer address answered: {}", errors.join("; "))
}

impl Runtime {
    pub async fn reconcile(&mut self, config: &Config, local: &Manifest) -> Result<Snapshot> {
        let mut snapshot = Snapshot::default();
        for (name, peer) in &config.peers {
            // A peer's own failure costs that peer and nothing else. Returning early here would
            // starve every peer sorted after it -- `peers` is a BTreeMap, so the same ones every
            // pass -- and skip the reaping below, leaking a worker for every peer ever removed.
            match self.reconcile_peer(config, local, name, peer).await {
                Ok(entry) => {
                    snapshot.peers.insert(name.clone(), entry);
                }
                Err(error) => eprintln!("nixaudiod: peer {name}: {error:#}"),
            }
        }

        // Staleness is a question about configuration, not about this pass. A peer whose control
        // endpoint blinked is still a peer we carry audio for; tearing its session down over one
        // unanswered manifest would turn a control-plane blip into an audible dropout.
        let stale: Vec<String> = self
            .workers
            .keys()
            .filter(|name| !config.peers.contains_key(*name))
            .cloned()
            .collect();
        for name in stale {
            if let Some(mut worker) = self.workers.remove(&name) {
                let _ = worker.child.kill().await;
                let _ = worker.child.wait().await;
            }
        }
        Ok(snapshot)
    }

    async fn reconcile_peer(
        &mut self,
        config: &Config,
        local: &Manifest,
        name: &str,
        peer: &PeerConfig,
    ) -> Result<PeerSnapshot> {
        let (address, remote) = fetch(peer).await?;
        let plan = plan(
            &config.node,
            name,
            &address,
            peer.audio_port,
            local,
            &remote,
        )?;
        let spec = worker_spec(&plan, &config.transport);

        let restart = match self.workers.get_mut(name) {
            Some(worker) if worker.spec == spec => worker.child.try_wait()?.is_some(),
            Some(worker) => {
                let _ = worker.child.kill().await;
                let _ = worker.child.wait().await;
                true
            }
            None => true,
        };
        if restart {
            let child = spawn_worker(&spec)?;
            self.workers.insert(name.to_owned(), Worker { spec, child });
        }
        Ok(PeerSnapshot {
            address,
            manifest: remote,
            plan,
        })
    }
}

async fn serve_connection(mut stream: TcpStream, manifest: Arc<RwLock<Manifest>>) -> Result<()> {
    let mut greeting = vec![0_u8; CONTROL_GREETING.len()];
    timeout(Duration::from_secs(2), stream.read_exact(&mut greeting))
        .await
        .context("control greeting timed out")??;
    if greeting != CONTROL_GREETING.as_bytes() {
        bail!("unsupported control greeting");
    }
    let bytes = serde_json::to_vec(&*manifest.read().unwrap())?;
    stream.write_all(&bytes).await?;
    stream.shutdown().await?;
    Ok(())
}

pub async fn serve(config: Config, manifest: Arc<RwLock<Manifest>>) -> Result<()> {
    let listener = TcpListener::bind((config.control.listen.as_str(), config.control.port))
        .await
        .with_context(|| {
            format!(
                "bind nixaudio control endpoint {}:{}",
                config.control.listen, config.control.port
            )
        })?;
    loop {
        let (stream, _) = listener.accept().await?;
        let manifest = manifest.clone();
        tokio::spawn(async move {
            if let Err(error) = serve_connection(stream, manifest).await {
                eprintln!("nixaudiod: control connection: {error:#}");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ControlConfig;

    fn endpoint(id: &str, channels: &[&str]) -> EndpointManifest {
        EndpointManifest {
            id: id.into(),
            label: id.into(),
            channels: channels.iter().map(|v| (*v).into()).collect(),
        }
    }

    #[test]
    fn one_connection_multiplexes_every_remote_output() {
        let local = Manifest {
            protocol: 1,
            node: "alpha".into(),
            revision: 1,
            outputs: vec![endpoint("local.speakers", &["FL", "FR"])],
            inputs: Vec::new(),
        };
        let remote = Manifest {
            protocol: 1,
            node: "beta".into(),
            revision: 7,
            outputs: vec![
                endpoint("local.hyperx", &["FL", "FR"]),
                endpoint("local.hdmi", &["FL", "FR", "FC", "LFE"]),
            ],
            inputs: Vec::new(),
        };
        let plan = plan("alpha", "beta", "beta.local", 46001, &local, &remote).unwrap();
        assert_eq!(plan.role, Role::Server);
        assert_eq!(plan.send_channels, 6);
        assert_eq!(plan.receive_channels, 2);
        assert_eq!(plan.send[0].endpoint, "local.hdmi");
        assert_eq!(plan.send[0].first, 1);
        assert_eq!(plan.send[1].endpoint, "local.hyperx");
        assert_eq!(plan.send[1].first, 5);
    }

    #[test]
    fn both_ends_derive_complementary_channel_counts() {
        let alpha = Manifest {
            protocol: 1,
            node: "alpha".into(),
            revision: 1,
            outputs: vec![endpoint("local.a", &["FL", "FR"])],
            inputs: Vec::new(),
        };
        let beta = Manifest {
            protocol: 1,
            node: "beta".into(),
            revision: 1,
            outputs: vec![endpoint("local.b", &["MONO"])],
            inputs: Vec::new(),
        };
        let a = plan("alpha", "beta", "beta", 46001, &alpha, &beta).unwrap();
        let b = plan("beta", "alpha", "alpha", 46001, &beta, &alpha).unwrap();
        assert_eq!(a.role, Role::Server);
        assert_eq!(b.role, Role::Client);
        assert_eq!(a.send_channels, b.receive_channels);
        assert_eq!(a.receive_channels, b.send_channels);
    }

    #[test]
    fn jacktrip_is_started_without_automatic_patching() {
        let plan = SessionPlan {
            peer: "beta".into(),
            address: "beta.local".into(),
            audio_port: 46001,
            node_name: "nixaudio-jt-beta".into(),
            role: Role::Client,
            send: Vec::new(),
            receive: Vec::new(),
            send_channels: 4,
            receive_channels: 2,
        };
        let args = arguments(&plan, &TransportConfig::default());
        assert!(args.windows(2).any(|v| v == ["--sendchannels", "4"]));
        assert!(args.windows(2).any(|v| v == ["--receivechannels", "2"]));
        assert!(args.iter().any(|v| v == "--zerounderrun"));
        assert!(args.iter().any(|v| v == "--nojackportsconnect"));
        assert_eq!(args[0], "--client");
    }

    #[tokio::test]
    async fn control_protocol_round_trips_manifest() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let address = listener.local_addr().unwrap();
        let manifest = Manifest {
            protocol: 1,
            node: "beta".into(),
            revision: 3,
            outputs: vec![endpoint("local.speakers", &["FL", "FR"])],
            inputs: Vec::new(),
        };
        let published = Arc::new(RwLock::new(manifest.clone()));
        let task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            serve_connection(stream, published).await.unwrap();
        });
        let received = fetch_at("127.0.0.1", address.port()).await.unwrap();
        task.await.unwrap();
        assert_eq!(received, manifest);
    }

    /// A peer that answers but is not who we expect is what a half-finished rollout looks like on
    /// the wire: both ends up, one of them still on the other revision. That must cost us that one
    /// peer and nothing else. `config.peers` is a BTreeMap, so returning early deterministically
    /// starves every peer sorted after the failing one, and skips stale-worker reaping entirely --
    /// which leaks a JackTrip child for every peer ever removed from the configuration.
    #[tokio::test]
    async fn one_unplannable_peer_costs_only_that_peer() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let control_port = listener.local_addr().unwrap().port();
        let published = Arc::new(RwLock::new(Manifest {
            protocol: 1,
            node: "somebody-else".into(),
            revision: 1,
            outputs: vec![endpoint("local.speakers", &["FL", "FR"])],
            inputs: Vec::new(),
        }));
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let _ = serve_connection(stream, published.clone()).await;
            }
        });

        let mut config = Config {
            node: "alpha".into(),
            control: ControlConfig::default(),
            transport: TransportConfig::default(),
            peers: BTreeMap::new(),
            catalogue: BTreeMap::new(),
        };
        config.peers.insert(
            "beta".into(),
            PeerConfig {
                addresses: vec!["127.0.0.1".into()],
                control_port,
                audio_port: 46001,
            },
        );
        let local = Manifest {
            protocol: 1,
            node: "alpha".into(),
            revision: 1,
            outputs: vec![endpoint("local.speakers", &["FL", "FR"])],
            inputs: Vec::new(),
        };

        let mut runtime = Runtime::default();
        runtime.workers.insert(
            "gamma".into(),
            Worker {
                spec: WorkerSpec {
                    command: vec!["true".into()],
                    arguments: Vec::new(),
                    latency: "128/48000".into(),
                },
                child: Command::new("sleep")
                    .arg("30")
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap(),
            },
        );

        let snapshot = runtime
            .reconcile(&config, &local)
            .await
            .expect("an unplannable peer must not abort the whole reconcile pass");

        assert!(
            snapshot.peers.is_empty(),
            "the rejected peer must not appear in the snapshot"
        );
        assert!(
            !runtime.workers.contains_key("gamma"),
            "a peer removed from the configuration must still be reaped when an earlier peer fails"
        );
    }

    /// A control endpoint that blinks is not a reason to drop audio that is already flowing. The
    /// reaper answers a question about configuration -- is this peer still declared? -- not about
    /// whether this particular pass happened to reach it.
    #[tokio::test]
    async fn a_configured_peer_that_fails_this_pass_keeps_its_session() {
        // Bind then drop, so the port is real, free, and certain to refuse.
        let closed = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let control_port = closed.local_addr().unwrap().port();
        drop(closed);

        let mut config = Config {
            node: "alpha".into(),
            control: ControlConfig::default(),
            transport: TransportConfig::default(),
            peers: BTreeMap::new(),
            catalogue: BTreeMap::new(),
        };
        config.peers.insert(
            "beta".into(),
            PeerConfig {
                addresses: vec!["127.0.0.1".into()],
                control_port,
                audio_port: 46001,
            },
        );
        let local = Manifest {
            protocol: 1,
            node: "alpha".into(),
            revision: 1,
            outputs: vec![endpoint("local.speakers", &["FL", "FR"])],
            inputs: Vec::new(),
        };

        let mut runtime = Runtime::default();
        runtime.workers.insert(
            "beta".into(),
            Worker {
                spec: WorkerSpec {
                    command: vec!["true".into()],
                    arguments: Vec::new(),
                    latency: "128/48000".into(),
                },
                child: Command::new("sleep")
                    .arg("30")
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap(),
            },
        );

        runtime.reconcile(&config, &local).await.unwrap();

        let worker = runtime
            .workers
            .get_mut("beta")
            .expect("a declared peer keeps its session across an unanswered manifest");
        assert!(
            worker.child.try_wait().unwrap().is_none(),
            "the running JackTrip session must not have been killed"
        );
    }
}
