use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct State {
    #[serde(default)]
    pub routes: BTreeMap<String, BTreeSet<String>>,
    pub default_output: Option<String>,
    pub default_input: Option<String>,
}

pub fn state_path() -> PathBuf {
    if let Some(root) = std::env::var_os("XDG_STATE_HOME") {
        return PathBuf::from(root).join("nixaudio/state.json");
    }
    let home = std::env::var_os("HOME").unwrap_or_else(|| ".".into());
    PathBuf::from(home).join(".local/state/nixaudio/state.json")
}

impl State {
    pub fn load(path: &Path) -> Result<Self> {
        match std::fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .with_context(|| format!("parse runtime state {}", path.display())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(error) => {
                Err(error).with_context(|| format!("read runtime state {}", path.display()))
            }
        }
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        let parent = path.parent().context("runtime state path has no parent")?;
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create runtime state directory {}", parent.display()))?;
        let temporary = path.with_extension(format!("json.tmp.{}", std::process::id()));
        let mut bytes = serde_json::to_vec_pretty(self)?;
        bytes.push(b'\n');
        std::fs::write(&temporary, bytes)
            .with_context(|| format!("write runtime state {}", temporary.display()))?;
        std::fs::rename(&temporary, path)
            .with_context(|| format!("install runtime state {}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_round_trips_atomically() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("nested/state.json");
        let mut state = State::default();
        state.routes.insert(
            "firefox|Music".into(),
            BTreeSet::from(["local.hyperx".into()]),
        );
        state.save(&path).unwrap();
        assert_eq!(State::load(&path).unwrap().routes, state.routes);
    }
}
