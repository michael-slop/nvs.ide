//! Workbench state as sent by runtime/lua/nvs/bridge.lua.

use serde::Deserialize;

#[derive(Clone, Debug, Default, Deserialize)]
pub struct BufferInfo {
    pub bufnr: i64,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub modified: bool,
    #[serde(default)]
    pub filetype: String,
    #[serde(default)]
    pub buftype: String,
    #[serde(default)]
    pub current: bool,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct CursorPos {
    #[serde(default)]
    pub line: i64,
    #[serde(default)]
    pub col: i64,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct DiagnosticCounts {
    #[serde(default)]
    pub error: i64,
    #[serde(default)]
    pub warn: i64,
    #[serde(default)]
    pub info: i64,
    #[serde(default)]
    pub hint: i64,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct AiState {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub model: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct NvimState {
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub buffers: Vec<BufferInfo>,
    #[serde(default)]
    pub current: i64,
    #[serde(default)]
    pub cursor: CursorPos,
    #[serde(default)]
    pub branch: String,
    #[serde(default)]
    pub diagnostics: DiagnosticCounts,
    #[serde(default)]
    pub buffer_diagnostics: DiagnosticCounts,
    #[serde(default)]
    pub lsp: Vec<String>,
    #[serde(default = "default_stage")]
    pub stage: u32,
    #[serde(default)]
    pub coach: String,
    /// The welcome screen was shown once (true after the first stage pick).
    #[serde(default = "welcomed_default")]
    pub welcomed: bool,
    #[serde(default)]
    pub ai: AiState,
}

fn default_stage() -> u32 {
    2
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Diagnostic {
    #[serde(default)]
    pub bufnr: i64,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub file: String,
    #[serde(default)]
    pub lnum: i64,
    #[serde(default)]
    pub col: i64,
    #[serde(default)]
    pub severity: String,
    #[serde(default)]
    pub message: String,
    #[serde(default)]
    pub source: String,
}

/// Decode a msgpack value the bridge sent into a typed struct.
pub fn decode<T: for<'de> Deserialize<'de>>(value: rmpv::Value) -> Result<T, String> {
    rmpv::ext::from_value(value).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rmpv::Value;

    fn map(entries: Vec<(&str, Value)>) -> Value {
        Value::Map(entries.into_iter().map(|(k, v)| (Value::from(k), v)).collect())
    }

    #[test]
    fn decodes_bridge_state() {
        let payload = map(vec![
            ("mode", Value::from("n")),
            ("cwd", Value::from("C:/Users/micha/nvs.ide")),
            ("buffers", Value::Array(vec![map(vec![("bufnr", Value::from(1)), ("name", Value::from("a.lua")), ("modified", Value::from(true)), ("current", Value::from(true))])])),
            ("current", Value::from(1)),
            ("cursor", map(vec![("line", Value::from(12)), ("col", Value::from(3))])),
            ("branch", Value::from("main")),
            ("diagnostics", map(vec![("error", Value::from(0)), ("warn", Value::from(2))])),
            ("lsp", Value::Array(vec![Value::from("lua_ls")])),
            ("stage", Value::from(2)),
            ("ai", map(vec![("enabled", Value::from(false)), ("model", Value::from(""))])),
        ]);
        let state: NvimState = decode(payload).expect("decode");
        assert_eq!(state.stage, 2);
        assert_eq!(state.cursor.line, 12);
        assert_eq!(state.cwd, "C:/Users/micha/nvs.ide");
        assert_eq!(state.buffers[0].name, "a.lua");
        assert_eq!(state.diagnostics.warn, 2);
    }
}

// Older bridges do not send `welcomed`; treat them as already welcomed so the screen never nags.
fn welcomed_default() -> bool {
    true
}
