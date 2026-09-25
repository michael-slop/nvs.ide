//! The part of `nvim_get_api_info` the shell needs: channel id and version.

use anyhow::{anyhow, Result};
use rmpv::Value;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ApiVersion {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
    pub prerelease: bool,
    pub api_level: u64,
}

impl ApiVersion {
    pub fn at_least(&self, major: u64, minor: u64, patch: u64) -> bool {
        (self.major, self.minor, self.patch) >= (major, minor, patch)
    }
}

impl std::fmt::Display for ApiVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}{}", self.major, self.minor, self.patch, if self.prerelease { "-dev" } else { "" })
    }
}

#[derive(Clone, Debug)]
pub struct ApiInfo {
    pub channel: u64,
    pub version: ApiVersion,
    /// The `ext_*` options this Neovim supports (`ui_options`).
    pub ui_options: Vec<String>,
}

fn field<'a>(map: &'a [(Value, Value)], key: &str) -> Option<&'a Value> {
    map.iter().find(|(k, _)| k.as_str() == Some(key)).map(|(_, v)| v)
}

pub fn parse_api_info(info: &[Value]) -> Result<ApiInfo> {
    let channel = info.first().and_then(Value::as_u64).ok_or_else(|| anyhow!("api_info has no channel id"))?;
    let meta = info.get(1).and_then(Value::as_map).ok_or_else(|| anyhow!("api_info has no metadata map"))?;
    let version_map = field(meta, "version").and_then(Value::as_map).ok_or_else(|| anyhow!("api_info has no version"))?;
    let num = |k: &str| field(version_map, k).and_then(Value::as_u64).unwrap_or(0);
    let version = ApiVersion {
        major: num("major"),
        minor: num("minor"),
        patch: num("patch"),
        prerelease: field(version_map, "prerelease").and_then(Value::as_bool).unwrap_or(false),
        api_level: num("api_level"),
    };
    let ui_options = field(meta, "ui_options")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    Ok(ApiInfo { channel, version, ui_options })
}
