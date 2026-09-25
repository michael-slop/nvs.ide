//! winit keyboard events to Neovim input strings.
//! Ported from Neovide's src/window/keyboard_manager.rs (MIT, LICENSE-NEOVIDE), Windows and
//! Linux paths only. The rules that matter:
//! - only key presses are sent, never releases; synthetic events are ignored;
//! - the OS-composed `text` is used for normal keys, so dead keys, AltGr and shifted layouts
//!   come out right; special keys use Neovim's names (<BS>, <F5>, <kEnter>...);
//! - Shift is only spelled out for special keys and for Ctrl+letter (<C-S-a>);
//! - `<` becomes `<lt>`, because a bare `<` would swallow the keys after it;
//! - Alt is Meta on Windows (<M-x>).

use winit::{
    event::{ElementState, Ime, KeyEvent, Modifiers, WindowEvent},
    keyboard::{Key, KeyCode, KeyLocation, NamedKey, PhysicalKey},
};

fn is_ascii_alphabetic_char(text: &str) -> bool {
    text.len() == 1 && text.chars().next().unwrap().is_ascii_alphabetic()
}

/// What a keyboard event turned into.
#[derive(Debug, Clone, PartialEq)]
pub enum KeyOutput {
    /// Send this through `nvim_input`.
    Input(String),
    /// IME composition text changed (shown by the shell, not sent).
    Preedit(String),
    Nothing,
}

#[derive(Default)]
pub struct KeyboardManager {
    modifiers: Modifiers,
    ime_preedit: String,
}

impl KeyboardManager {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn modifiers(&self) -> Modifiers {
        self.modifiers
    }

    pub fn handle_event(&mut self, event: &WindowEvent) -> KeyOutput {
        match event {
            WindowEvent::KeyboardInput { event: key_event, is_synthetic: false, .. } if self.ime_preedit.is_empty() => {
                if key_event.state == ElementState::Pressed {
                    if let Some(text) = self.format_key(key_event) {
                        return KeyOutput::Input(text);
                    }
                }
                KeyOutput::Nothing
            }
            WindowEvent::Ime(Ime::Commit(text)) => KeyOutput::Input(self.format_key_text(text, false)),
            WindowEvent::Ime(Ime::Preedit(text, _cursor)) => {
                self.ime_preedit = text.to_string();
                KeyOutput::Preedit(text.to_string())
            }
            WindowEvent::ModifiersChanged(modifiers) => {
                self.modifiers = *modifiers;
                KeyOutput::Nothing
            }
            _ => KeyOutput::Nothing,
        }
    }

    fn format_key(&self, key_event: &KeyEvent) -> Option<String> {
        if let Some(text) = get_special_key(key_event) {
            Some(self.format_key_text(text, true))
        } else {
            self.format_normal_key(key_event)
        }
    }

    fn format_normal_key(&self, key_event: &KeyEvent) -> Option<String> {
        key_event
            .text
            .as_ref()
            .map(|t| t.as_str())
            .or(match &key_event.logical_key {
                Key::Character(text) => Some(text.as_str()),
                _ => None,
            })
            .map(|text| self.format_key_text(text, false))
    }

    pub fn format_key_text(&self, text: &str, is_special: bool) -> String {
        // Neovim uppercases shifted ascii letters itself; do it here so winit's occasional
        // lowercase report does not lose the shift.
        let text = if self.modifiers.state().shift_key() && is_ascii_alphabetic_char(text) { text.to_uppercase() } else { text.to_string() };
        let modifiers = self.format_modifier_string(&text, is_special);
        let (text, is_special) = if text == "<" { ("lt".to_string(), true) } else { (text, is_special) };
        if modifiers.is_empty() {
            if is_special {
                format!("<{text}>")
            } else {
                text
            }
        } else {
            format!("<{modifiers}{text}>")
        }
    }

    /// "S-C-M-D-" style prefix. Shift only with special keys or Ctrl+letter; see the module docs.
    pub fn format_modifier_string(&self, text: &str, is_special: bool) -> String {
        let state = self.modifiers.state();
        let include_shift = is_special || (state.control_key() && is_ascii_alphabetic_char(text));
        let mut out = String::new();
        if state.shift_key() && include_shift {
            out += "S-";
        }
        if state.control_key() {
            out += "C-";
        }
        if state.alt_key() {
            out += "M-";
        }
        if state.super_key() {
            out += "D-";
        }
        out
    }
}

fn numpad(is_numlock: bool, numlock: &'static str, other: &'static str) -> Option<&'static str> {
    Some(if is_numlock { numlock } else { other })
}

fn handle_numpad_key(key_event: &KeyEvent) -> Option<&str> {
    let PhysicalKey::Code(code) = key_event.physical_key else { return None };
    let is_numlock = key_event.text.is_some();
    match code {
        KeyCode::NumpadDivide => Some("kDivide"),
        KeyCode::NumpadMultiply => Some("kMultiply"),
        KeyCode::NumpadSubtract => Some("kMinus"),
        KeyCode::NumpadAdd => Some("kPlus"),
        KeyCode::NumpadEnter => Some("kEnter"),
        KeyCode::NumpadEqual => Some("kEqual"),
        KeyCode::NumpadComma => match key_event.logical_key.as_ref() {
            Key::Character(",") => Some("kComma"),
            Key::Character(".") => Some("kPoint"),
            _ => None,
        },
        KeyCode::NumpadDecimal => {
            if is_numlock {
                match key_event.logical_key.as_ref() {
                    Key::Character(",") => Some("kComma"),
                    Key::Character(".") => Some("kPoint"),
                    _ => None,
                }
            } else {
                Some("kDel")
            }
        }
        KeyCode::Numpad9 => numpad(is_numlock, "k9", "kPageUp"),
        KeyCode::Numpad8 => numpad(is_numlock, "k8", "kUp"),
        KeyCode::Numpad7 => numpad(is_numlock, "k7", "kHome"),
        KeyCode::Numpad6 => numpad(is_numlock, "k6", "kRight"),
        KeyCode::Numpad5 => numpad(is_numlock, "k5", "kOrigin"),
        KeyCode::Numpad4 => numpad(is_numlock, "k4", "kLeft"),
        KeyCode::Numpad3 => numpad(is_numlock, "k3", "kPageDown"),
        KeyCode::Numpad2 => numpad(is_numlock, "k2", "kDown"),
        KeyCode::Numpad1 => numpad(is_numlock, "k1", "kEnd"),
        KeyCode::Numpad0 => numpad(is_numlock, "k0", "Insert"),
        _ => None,
    }
}

fn get_special_key(key_event: &KeyEvent) -> Option<&str> {
    if key_event.location == KeyLocation::Numpad {
        return handle_numpad_key(key_event);
    }
    let Key::Named(key) = &key_event.logical_key else { return None };
    Some(match key {
        NamedKey::ArrowDown => "Down",
        NamedKey::ArrowLeft => "Left",
        NamedKey::ArrowRight => "Right",
        NamedKey::ArrowUp => "Up",
        NamedKey::Backspace => "BS",
        NamedKey::Delete => "Del",
        NamedKey::End => "End",
        NamedKey::Enter => "Enter",
        NamedKey::Escape => "Esc",
        NamedKey::F1 => "F1",
        NamedKey::F2 => "F2",
        NamedKey::F3 => "F3",
        NamedKey::F4 => "F4",
        NamedKey::F5 => "F5",
        NamedKey::F6 => "F6",
        NamedKey::F7 => "F7",
        NamedKey::F8 => "F8",
        NamedKey::F9 => "F9",
        NamedKey::F10 => "F10",
        NamedKey::F11 => "F11",
        NamedKey::F12 => "F12",
        NamedKey::F13 => "F13",
        NamedKey::F14 => "F14",
        NamedKey::F15 => "F15",
        NamedKey::F16 => "F16",
        NamedKey::F17 => "F17",
        NamedKey::F18 => "F18",
        NamedKey::F19 => "F19",
        NamedKey::F20 => "F20",
        NamedKey::F21 => "F21",
        NamedKey::F22 => "F22",
        NamedKey::F23 => "F23",
        NamedKey::F24 => "F24",
        NamedKey::Home => "Home",
        NamedKey::Insert => "Insert",
        NamedKey::PageDown => "PageDown",
        NamedKey::PageUp => "PageUp",
        NamedKey::Space => {
            // Space can finish a dead-key sequence; then it is not the Space key.
            if key_event.text.as_deref() == Some(" ") || key_event.text.is_none() {
                "Space"
            } else {
                return None;
            }
        }
        NamedKey::Tab => "Tab",
        _ => return None,
    })
}
