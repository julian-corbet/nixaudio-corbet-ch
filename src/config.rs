use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::PathBuf};

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default = "default_loop")]
    pub loop_name: String,
    #[serde(default)]
    pub mirror_priority: i32,
    #[serde(default)]
    pub peers: BTreeMap<String, String>,
    #[serde(default)]
    pub catalogue: BTreeMap<String, CatalogueEntry>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CatalogueEntry {
    pub origin: String,
    pub peer: Option<String>,
    pub device: String,
    pub description: Option<String>,
    pub known: String,
}

fn default_port() -> u16 {
    4713
}
fn default_loop() -> String {
    "fabric-loop.0".into()
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
        serde_json::from_slice(&bytes)
            .with_context(|| format!("parse nixaudio configuration {}", path.display()))
    }
}
