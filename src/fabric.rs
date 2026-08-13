use crate::config::Config;
use anyhow::{bail, Context, Result};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    net::{SocketAddr, TcpStream, ToSocketAddrs},
    process::Command,
    time::Duration,
};

#[derive(Clone, Debug)]
struct RemoteDevice {
    name: String,
    stable: String,
}

#[derive(Clone, Debug)]
struct Tunnel {
    module: String,
}

fn is_fabric_name(name: &str) -> bool {
    ["fabric_", "fabricsrc_", "nixaudio_"]
        .iter()
        .any(|prefix| name.starts_with(prefix))
}

fn run(arguments: &[String]) -> Result<std::process::Output> {
    Command::new("timeout")
        .args(["--kill-after=1s", "6s", "pactl"])
        .args(arguments)
        .output()
        .context("run pactl")
}

fn peer_args(address: &str, port: u16) -> Vec<String> {
    vec!["-s".into(), format!("tcp:{address}:{port}")]
}

fn remote_devices(address: &str, port: u16, kind: &str) -> Result<Vec<RemoteDevice>> {
    let mut arguments = peer_args(address, port);
    arguments.extend(["-f".into(), "json".into(), "list".into(), kind.into()]);
    let output = run(&arguments)?;
    if !output.status.success() {
        bail!("peer {address} did not enumerate {kind}");
    }
    let values: Vec<Value> =
        serde_json::from_slice(&output.stdout).context("parse remote pactl JSON")?;
    Ok(values
        .into_iter()
        .filter_map(|value| {
            let name = value.get("name")?.as_str()?.to_owned();
            if is_fabric_name(&name) || name.ends_with(".monitor") || name.starts_with("tunnel.") {
                return None;
            }
            let stable = value
                .get("properties")
                .and_then(|v| v.get("alsa.nixaudio.device"))
                .and_then(Value::as_str)
                .unwrap_or(&name)
                .to_owned();
            Some(RemoteDevice { name, stable })
        })
        .collect())
}

fn loaded() -> Result<BTreeMap<String, Tunnel>> {
    let arguments = vec!["list".into(), "short".into(), "modules".into()];
    let output = run(&arguments)?;
    if !output.status.success() {
        bail!("local pactl module enumeration failed");
    }
    let mut tunnels = BTreeMap::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() < 3 || !matches!(fields[1], "module-tunnel-sink" | "module-tunnel-source") {
            continue;
        }
        for argument in fields[2].split_whitespace() {
            if let Some(name) = argument
                .strip_prefix("sink_name=")
                .or_else(|| argument.strip_prefix("source_name="))
            {
                if is_fabric_name(name) {
                    tunnels.insert(
                        name.to_owned(),
                        Tunnel {
                            module: fields[0].to_owned(),
                        },
                    );
                }
            }
        }
    }
    Ok(tunnels)
}

fn safe(value: &str) -> String {
    value
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect::<String>()
        .trim_matches('_')
        .to_owned()
}

fn tunnel_name(direction: &str, peer: &str, remote: &str) -> String {
    format!(
        "nixaudio_{}_{}_{}",
        direction,
        safe(peer),
        &format!("{:x}", md5::compute(remote.as_bytes()))[..10]
    )
}

fn endpoint(address: &str, port: u16) -> Option<SocketAddr> {
    (address, port).to_socket_addrs().ok()?.next()
}

fn reachable(address: &str, port: u16) -> bool {
    endpoint(address, port)
        .and_then(|address| TcpStream::connect_timeout(&address, Duration::from_millis(800)).ok())
        .is_some()
}

fn load_tunnel(
    config: &Config,
    address: &str,
    peer: &str,
    direction: &str,
    device: &RemoteDevice,
    local_name: &str,
) -> Result<()> {
    let (module, endpoint_key, name_key) = if direction == "out" {
        ("module-tunnel-sink", "sink", "sink_name")
    } else {
        ("module-tunnel-source", "source", "source_name")
    };
    let properties = format!(
        "{endpoint_key}_properties=\"node.loop.name={} priority.session={} nixaudio.peer={} nixaudio.device={} nixaudio.remote.node={}\"",
        config.loop_name, config.mirror_priority, safe(peer), safe(&device.stable), device.name
    );
    let arguments = vec![
        "load-module".into(),
        module.into(),
        format!("server=tcp:{address}:{}", config.port),
        format!("{endpoint_key}={}", device.name),
        format!("{name_key}={local_name}"),
        "reconnect_interval_ms=15000".into(),
        properties,
    ];
    let output = run(&arguments)?;
    if output.status.success() {
        Ok(())
    } else {
        bail!(
            "load {local_name}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )
    }
}

pub fn reconcile(config: &Config) -> Result<()> {
    if config.peers.is_empty() {
        return Ok(());
    }
    let self_host = hostname::get()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase();
    let have = loaded()?;
    let mut want = BTreeSet::new();
    for (address, peer) in &config.peers {
        if peer.to_lowercase() == self_host || !reachable(address, config.port) {
            continue;
        }
        let sinks = remote_devices(address, config.port, "sinks").unwrap_or_default();
        let sources = remote_devices(address, config.port, "sources").unwrap_or_default();
        for (direction, devices) in [("out", sinks), ("in", sources)] {
            for device in devices {
                let name = tunnel_name(direction, peer, &device.name);
                want.insert(name.clone());
                if !have.contains_key(&name) {
                    load_tunnel(config, address, peer, direction, &device, &name)?;
                }
            }
        }
    }
    for (name, tunnel) in have {
        if !want.contains(&name) {
            let arguments = vec!["unload-module".into(), tunnel.module];
            let _ = run(&arguments);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_deterministic_and_peer_scoped() {
        assert_eq!(
            tunnel_name("out", "Host B", "alsa_output.usb-1"),
            tunnel_name("out", "Host B", "alsa_output.usb-1")
        );
        assert_ne!(
            tunnel_name("out", "Host B", "alsa_output.usb-1"),
            tunnel_name("out", "Host C", "alsa_output.usb-1")
        );
    }
}
