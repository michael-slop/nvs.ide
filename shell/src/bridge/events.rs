//! Redraw-event parser for Neovim's external UI protocol (ext_linegrid + ext_multigrid,
//! plus the cmdline/message/tabline/popupmenu families, which the shell parses so it can
//! ignore them safely when a plugin such as noice.nvim forces those flags on).
//!
//! Ported from Neovide's src/bridge/events.rs (MIT, LICENSE-NEOVIDE) with skia's Color4f
//! replaced by our own `Rgba` and Neovide-only events dropped.

use std::{convert::TryInto, error, fmt};

use rmpv::Value;

use crate::color::Rgba;
use crate::editor::{Colors, CursorMode, CursorShape, Style, UnderlineStyle};

#[derive(Clone, Debug)]
pub enum ParseError {
    Array(Value),
    Map(Value),
    String(Value),
    U64(Value),
    I64(Value),
    F64(Value),
    Bool(Value),
    WindowAnchor(Value),
    Format(String),
}
type Result<T> = std::result::Result<T, ParseError>;

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            ParseError::Array(v) => write!(f, "invalid array format {v}"),
            ParseError::Map(v) => write!(f, "invalid map format {v}"),
            ParseError::String(v) => write!(f, "invalid string format {v}"),
            ParseError::U64(v) => write!(f, "invalid u64 format {v}"),
            ParseError::I64(v) => write!(f, "invalid i64 format {v}"),
            ParseError::F64(v) => write!(f, "invalid f64 format {v}"),
            ParseError::Bool(v) => write!(f, "invalid bool format {v}"),
            ParseError::WindowAnchor(v) => write!(f, "invalid window anchor format {v}"),
            ParseError::Format(s) => write!(f, "invalid event format {s}"),
        }
    }
}

impl error::Error for ParseError {}

#[derive(Clone, Debug)]
pub struct GridLineCell {
    /// UTF-8 text for the cell; empty for the right half of a double-width char.
    pub text: String,
    /// Highlight id from an earlier `hl_attr_define`; `None` means "same as the previous cell".
    pub highlight_id: Option<u64>,
    /// Repeat count; `None` draws once.
    pub repeat: Option<u64>,
}

pub type StyledContent = Vec<(u64, String)>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MessageKind {
    Unknown,
    Confirm,
    ConfirmSubstitute,
    Error,
    Echo,
    EchoMessage,
    EchoError,
    LuaError,
    RpcError,
    ReturnPrompt,
    QuickFix,
    SearchCount,
    Warning,
}

impl MessageKind {
    pub fn parse(kind: &str) -> MessageKind {
        match kind {
            "confirm" => MessageKind::Confirm,
            "confirm_sub" => MessageKind::ConfirmSubstitute,
            "emsg" => MessageKind::Error,
            "echo" => MessageKind::Echo,
            "echomsg" => MessageKind::EchoMessage,
            "echoerr" => MessageKind::EchoError,
            "lua_error" => MessageKind::LuaError,
            "rpc_error" => MessageKind::RpcError,
            "return_prompt" => MessageKind::ReturnPrompt,
            "quickfix" => MessageKind::QuickFix,
            "search_count" => MessageKind::SearchCount,
            "wmsg" => MessageKind::Warning,
            _ => MessageKind::Unknown,
        }
    }
}

#[derive(Clone, Debug)]
pub enum GuiOption {
    ArabicShape(bool),
    AmbiWidth(String),
    Emoji(bool),
    GuiFont(String),
    GuiFontSet(String),
    GuiFontWide(String),
    LineSpace(f64),
    Pumblend(u64),
    ShowTabLine(u64),
    TermGuiColors(bool),
    /// `ext_*` flags and anything else: name and raw value.
    Unknown(String, Value),
}

#[derive(Clone, Debug, PartialEq)]
pub enum WindowAnchor {
    NorthWest,
    NorthEast,
    SouthWest,
    SouthEast,
    /// Position given directly in grid-1 coordinates (Neovim composed the layout for us).
    Absolute,
}

#[derive(Clone, Debug, PartialEq)]
pub enum EditorMode {
    Normal,
    Insert,
    Visual,
    Replace,
    CmdLine,
    Unknown(String),
}

/// One tab page entry of `tabline_update`.
#[derive(Clone, Debug, PartialEq)]
pub struct TabEntry {
    pub handle: Value,
    pub name: String,
}

/// One buffer entry of `tabline_update`.
#[derive(Clone, Debug, PartialEq)]
pub struct BufferEntry {
    pub handle: Value,
    pub name: String,
}

#[derive(Clone, Debug)]
pub enum RedrawEvent {
    SetTitle { title: String },
    ModeInfoSet { cursor_modes: Vec<CursorMode> },
    OptionSet { gui_option: GuiOption },
    ModeChange { mode: EditorMode, mode_index: u64 },
    MouseOn,
    MouseOff,
    BusyStart,
    BusyStop,
    Flush,
    Resize { grid: u64, width: u64, height: u64 },
    DefaultColorsSet { colors: Colors },
    HighlightAttributesDefine { id: u64, style: Style, name: Option<String> },
    HighlightGroupSet { name: String, id: u64 },
    GridLine { grid: u64, row: u64, column_start: u64, cells: Vec<GridLineCell> },
    Clear { grid: u64 },
    Destroy { grid: u64 },
    CursorGoto { grid: u64, row: u64, column: u64 },
    Scroll { grid: u64, top: u64, bottom: u64, left: u64, right: u64, rows: i64, columns: i64 },
    WindowPosition { grid: u64, start_row: u64, start_column: u64, width: u64, height: u64 },
    WindowFloatPosition {
        grid: u64,
        anchor: WindowAnchor,
        anchor_grid: u64,
        anchor_row: f64,
        anchor_column: f64,
        mouse_enabled: bool,
        z_index: u64,
        comp_index: Option<u64>,
        screen_row: Option<u64>,
        screen_col: Option<u64>,
    },
    WindowExternalPosition { grid: u64 },
    WindowHide { grid: u64 },
    WindowClose { grid: u64 },
    MessageSetPosition {
        grid: u64,
        row: u64,
        scrolled: bool,
        separator_character: String,
        z_index: Option<u64>,
        comp_index: Option<u64>,
    },
    WindowViewport {
        grid: u64,
        top_line: f64,
        bottom_line: f64,
        current_line: f64,
        current_column: f64,
        line_count: Option<f64>,
        scroll_delta: Option<f64>,
    },
    WindowViewportMargins { grid: u64, top: u64, bottom: u64, left: u64, right: u64 },
    TablineUpdate {
        current_tab: Value,
        tabs: Vec<TabEntry>,
        current_buffer: Value,
        buffers: Vec<BufferEntry>,
    },
    CommandLineShow {
        content: StyledContent,
        position: u64,
        first_character: String,
        prompt: String,
        indent: u64,
        level: u64,
    },
    CommandLinePosition { position: u64, level: u64 },
    CommandLineSpecialCharacter { character: String, shift: bool, level: u64 },
    CommandLineHide,
    CommandLineBlockShow { lines: Vec<StyledContent> },
    CommandLineBlockAppend { line: StyledContent },
    CommandLineBlockHide,
    MessageShow { kind: MessageKind, content: StyledContent, replace_last: bool, append: bool },
    MessageClear,
    MessageShowMode { content: StyledContent },
    MessageShowCommand { content: StyledContent },
    MessageRuler { content: StyledContent },
    MessageHistoryShow { entries: Vec<(MessageKind, StyledContent)> },
    PopupmenuShow { items: Vec<Vec<String>>, selected: i64, row: u64, col: u64, grid: u64 },
    PopupmenuSelect { selected: i64 },
    PopupmenuHide,
    Suspend,
    Restart { listen_addr: String },
}

fn unpack_color(packed: u64) -> Rgba {
    Rgba::from_packed(packed)
}

fn extract_values<const REQ: usize>(values: Vec<Value>) -> Result<[Value; REQ]> {
    if REQ > values.len() {
        Err(ParseError::Format(format!("{values:?}")))
    } else {
        let mut required = vec![Value::Nil; REQ];
        for (index, value) in values.into_iter().enumerate() {
            if index < REQ {
                required[index] = value;
            }
        }
        Ok(required.try_into().unwrap())
    }
}

fn extract_values_with_optional<const REQ: usize, const OPT: usize>(
    values: Vec<Value>,
) -> Result<([Value; REQ], [Option<Value>; OPT])> {
    if REQ > values.len() {
        Err(ParseError::Format(format!("{values:?}")))
    } else {
        let mut required = vec![Value::Nil; REQ];
        let mut optional = vec![None; OPT];
        for (index, value) in values.into_iter().enumerate() {
            if index < REQ {
                required[index] = value;
            } else if index - REQ < OPT {
                optional[index - REQ] = Some(value);
            }
        }
        Ok((required.try_into().unwrap(), optional.try_into().unwrap()))
    }
}

fn parse_array(v: Value) -> Result<Vec<Value>> {
    v.try_into().map_err(ParseError::Array)
}

fn parse_map(v: Value) -> Result<Vec<(Value, Value)>> {
    v.try_into().map_err(ParseError::Map)
}

fn parse_string(v: Value) -> Result<String> {
    match v {
        Value::String(s) => Ok(s.into_str().unwrap_or_else(|| String::from("\u{FFFD}"))),
        _ => Err(ParseError::String(v)),
    }
}

fn parse_u64(v: Value) -> Result<u64> {
    v.try_into().map_err(ParseError::U64)
}

fn parse_i64(v: Value) -> Result<i64> {
    v.try_into().map_err(ParseError::I64)
}

fn parse_f64(v: Value) -> Result<f64> {
    v.try_into().map_err(ParseError::F64)
}

fn parse_bool(v: Value) -> Result<bool> {
    v.try_into().map_err(ParseError::Bool)
}

fn parse_set_title(args: Vec<Value>) -> Result<RedrawEvent> {
    let [title] = extract_values(args)?;
    Ok(RedrawEvent::SetTitle { title: parse_string(title)? })
}

fn parse_restart(args: Vec<Value>) -> Result<RedrawEvent> {
    let [addr] = extract_values(args)?;
    Ok(RedrawEvent::Restart { listen_addr: parse_string(addr)? })
}

fn parse_mode_info_set(args: Vec<Value>) -> Result<RedrawEvent> {
    let [_cursor_style_enabled, mode_info] = extract_values(args)?;
    let mode_info_values = parse_array(mode_info)?;
    let mut cursor_modes = Vec::with_capacity(mode_info_values.len());
    for mode_info_value in mode_info_values {
        let info_map = parse_map(mode_info_value)?;
        let mut mode_info = CursorMode::default();
        for (name, value) in info_map {
            match parse_string(name)?.as_str() {
                "cursor_shape" => mode_info.shape = CursorShape::from_type_name(&parse_string(value)?),
                "cell_percentage" => mode_info.cell_percentage = Some(parse_u64(value)? as f32 / 100.0),
                "blinkwait" => mode_info.blinkwait = Some(parse_u64(value)?),
                "blinkon" => mode_info.blinkon = Some(parse_u64(value)?),
                "blinkoff" => mode_info.blinkoff = Some(parse_u64(value)?),
                "attr_id" => mode_info.style_id = Some(parse_u64(value)?),
                _ => {}
            }
        }
        cursor_modes.push(mode_info);
    }
    Ok(RedrawEvent::ModeInfoSet { cursor_modes })
}

fn parse_option_set(args: Vec<Value>) -> Result<RedrawEvent> {
    let [name, value] = extract_values(args)?;
    let name = parse_string(name)?;
    Ok(RedrawEvent::OptionSet {
        gui_option: match name.as_str() {
            "arabicshape" => GuiOption::ArabicShape(parse_bool(value)?),
            "ambiwidth" => GuiOption::AmbiWidth(parse_string(value)?),
            "emoji" => GuiOption::Emoji(parse_bool(value)?),
            "guifont" => GuiOption::GuiFont(parse_string(value)?),
            "guifontset" => GuiOption::GuiFontSet(parse_string(value)?),
            "guifontwide" => GuiOption::GuiFontWide(parse_string(value)?),
            "linespace" => GuiOption::LineSpace(parse_f64(value)?),
            "pumblend" => GuiOption::Pumblend(parse_u64(value)?),
            "showtabline" => GuiOption::ShowTabLine(parse_u64(value)?),
            "termguicolors" => GuiOption::TermGuiColors(parse_bool(value)?),
            _ => GuiOption::Unknown(name, value),
        },
    })
}

fn parse_mode_change(args: Vec<Value>) -> Result<RedrawEvent> {
    let [mode, mode_index] = extract_values(args)?;
    let mode_name = parse_string(mode)?;
    Ok(RedrawEvent::ModeChange {
        mode: match mode_name.as_str() {
            "normal" => EditorMode::Normal,
            "insert" => EditorMode::Insert,
            "visual" => EditorMode::Visual,
            "replace" => EditorMode::Replace,
            "cmdline_normal" | "cmdline_insert" | "cmdline_replace" => EditorMode::CmdLine,
            _ => EditorMode::Unknown(mode_name),
        },
        mode_index: parse_u64(mode_index)?,
    })
}

fn parse_grid_resize(args: Vec<Value>) -> Result<RedrawEvent> {
    let [grid, width, height] = extract_values(args)?;
    Ok(RedrawEvent::Resize { grid: parse_u64(grid)?, width: parse_u64(width)?, height: parse_u64(height)? })
}

fn parse_default_colors(args: Vec<Value>) -> Result<RedrawEvent> {
    let [fg, bg, sp, _term_fg, _term_bg] = extract_values(args)?;
    Ok(RedrawEvent::DefaultColorsSet {
        colors: Colors {
            foreground: Some(unpack_color(parse_u64(fg)?)),
            background: Some(unpack_color(parse_u64(bg)?)),
            special: Some(unpack_color(parse_u64(sp)?)),
        },
    })
}

fn parse_style(style_map: Value) -> Result<Style> {
    let attributes = parse_map(style_map)?;
    let mut style = Style::new(Colors::new(None, None, None));
    for (name, value) in attributes {
        if let Value::String(name) = name {
            match (name.as_str().unwrap_or(""), value) {
                ("foreground", Value::Integer(c)) => style.colors.foreground = c.as_u64().map(unpack_color),
                ("background", Value::Integer(c)) => style.colors.background = c.as_u64().map(unpack_color),
                ("special", Value::Integer(c)) => style.colors.special = c.as_u64().map(unpack_color),
                ("reverse", Value::Boolean(b)) => style.reverse = b,
                ("italic", Value::Boolean(b)) => style.italic = b,
                ("bold", Value::Boolean(b)) => style.bold = b,
                ("strikethrough", Value::Boolean(b)) => style.strikethrough = b,
                ("blend", Value::Integer(b)) => style.blend = b.as_u64().unwrap_or(0) as u8,
                ("underline", Value::Boolean(true)) => style.underline = Some(UnderlineStyle::Underline),
                ("undercurl", Value::Boolean(true)) => style.underline = Some(UnderlineStyle::UnderCurl),
                ("underdotted" | "underdot", Value::Boolean(true)) => style.underline = Some(UnderlineStyle::UnderDot),
                ("underdashed" | "underdash", Value::Boolean(true)) => style.underline = Some(UnderlineStyle::UnderDash),
                ("underdouble" | "underlineline", Value::Boolean(true)) => style.underline = Some(UnderlineStyle::UnderDouble),
                _ => {}
            }
        }
    }
    Ok(style)
}

fn parse_hl_name(infos: Value) -> Option<String> {
    fn take_names(values: Vec<(Value, Value)>, names: &mut Vec<String>) {
        for (key, value) in values {
            let Some(key) = key.as_str() else { continue };
            if !["hi_name", "ui_name", "name", "link"].contains(&key) {
                continue;
            }
            if let Some(name) = value.as_str() {
                names.push(name.to_string());
            }
        }
    }
    let mut names = Vec::new();
    match infos {
        Value::Map(values) => take_names(values, &mut names),
        Value::Array(values) => {
            for value in values {
                if let Value::Map(v) = value {
                    take_names(v, &mut names);
                }
            }
        }
        _ => {}
    }
    names.into_iter().next()
}

fn parse_hl_attr_define(args: Vec<Value>) -> Result<RedrawEvent> {
    let [id, attributes, _terminal_attributes, infos] = extract_values(args)?;
    let style = parse_style(attributes)?;
    Ok(RedrawEvent::HighlightAttributesDefine { id: parse_u64(id)?, style, name: parse_hl_name(infos) })
}

fn parse_hl_group_set(args: Vec<Value>) -> Result<RedrawEvent> {
    let [name, id] = extract_values(args)?;
    Ok(RedrawEvent::HighlightGroupSet { name: parse_string(name)?, id: parse_u64(id)? })
}

fn parse_grid_line_cell(cell: Value) -> Result<GridLineCell> {
    fn take(v: &mut Value) -> Value {
        std::mem::replace(v, Value::Nil)
    }
    let mut contents = parse_array(cell)?;
    let text = contents.first_mut().map(take).ok_or_else(|| ParseError::Format(format!("{contents:?}")))?;
    let highlight_id = contents.get_mut(1).map(take).map(parse_u64).transpose()?;
    let repeat = contents.get_mut(2).map(take).map(parse_u64).transpose()?;
    Ok(GridLineCell { text: parse_string(text)?, highlight_id, repeat })
}

fn parse_grid_line(args: Vec<Value>) -> Result<RedrawEvent> {
    let [grid, row, column_start, cells] = extract_values(args)?;
    Ok(RedrawEvent::GridLine {
        grid: parse_u64(grid)?,
        row: parse_u64(row)?,
        column_start: parse_u64(column_start)?,
        cells: parse_array(cells)?.into_iter().map(parse_grid_line_cell).collect::<Result<Vec<_>>>()?,
    })
}

fn parse_grid_clear(args: Vec<Value>) -> Result<RedrawEvent> {
    let [grid] = extract_values(args)?;
    Ok(RedrawEvent::Clear { grid: parse_u64(grid)? })
}

fn parse_grid_destroy(args: Vec<Value>) -> Result<RedrawEvent> {
    let [grid] = extract_values(args)?;
    Ok(RedrawEvent::Destroy { grid: parse_u64(grid)? })
}

fn non_negative(v: i64) -> u64 {
    if v < 0 {
        0
    } else {
        v as u64
    }
}

fn parse_grid_cursor_goto(args: Vec<Value>) -> Result<RedrawEvent> {
    let [grid, row, column] = extract_values(args)?;
    Ok(RedrawEvent::CursorGoto {
        grid: parse_u64(grid)?,
        row: non_negative(parse_i64(row)?),
        column: non_negative(parse_i64(column)?),
    })
}

fn parse_grid_scroll(args: Vec<Value>) -> Result<RedrawEvent> {
    let [grid, top, bottom, left, right, rows, columns] = extract_values(args)?;
    Ok(RedrawEvent::Scroll {
        grid: parse_u64(grid)?,
        top: parse_u64(top)?,
        bottom: parse_u64(bottom)?,
        left: parse_u64(left)?,
        right: parse_u64(right)?,
        rows: parse_i64(rows)?,
        columns: parse_i64(columns)?,
    })
}

fn parse_win_pos(args: Vec<Value>) -> Result<RedrawEvent> {
    let [grid, _window, start_row, start_column, width, height] = extract_values(args)?;
    Ok(RedrawEvent::WindowPosition {
        grid: parse_u64(grid)?,
        start_row: parse_u64(start_row)?,
        start_column: parse_u64(start_column)?,
        width: parse_u64(width)?,
        height: parse_u64(height)?,
    })
}

fn parse_window_anchor(v: Value) -> Result<WindowAnchor> {
    let s = parse_string(v)?;
    match s.as_str() {
        "NW" => Ok(WindowAnchor::NorthWest),
        "NE" => Ok(WindowAnchor::NorthEast),
        "SW" => Ok(WindowAnchor::SouthWest),
        "SE" => Ok(WindowAnchor::SouthEast),
        _ => Err(ParseError::WindowAnchor(s.into())),
    }
}

fn parse_win_float_pos(args: Vec<Value>) -> Result<RedrawEvent> {
    let ([grid, _window, anchor, anchor_grid, anchor_row, anchor_column, mouse_enabled, z_index], [comp_index, screen_row, screen_col]) =
        extract_values_with_optional(args)?;
    Ok(RedrawEvent::WindowFloatPosition {
        grid: parse_u64(grid)?,
        anchor: parse_window_anchor(anchor)?,
        anchor_grid: parse_u64(anchor_grid)?,
        anchor_row: parse_f64(anchor_row)?,
        anchor_column: parse_f64(anchor_column)?,
        mouse_enabled: parse_bool(mouse_enabled)?,
        z_index: parse_u64(z_index)?,
        comp_index: comp_index.map(parse_u64).transpose()?,
        screen_row: screen_row.map(parse_u64).transpose()?,
        screen_col: screen_col.map(parse_u64).transpose()?,
    })
}

fn parse_win_external_pos(args: Vec<Value>) -> Result<RedrawEvent> {
    let [grid, _window] = extract_values(args)?;
    Ok(RedrawEvent::WindowExternalPosition { grid: parse_u64(grid)? })
}

fn parse_win_hide(args: Vec<Value>) -> Result<RedrawEvent> {
    let [grid] = extract_values(args)?;
    Ok(RedrawEvent::WindowHide { grid: parse_u64(grid)? })
}

fn parse_win_close(args: Vec<Value>) -> Result<RedrawEvent> {
    let [grid] = extract_values(args)?;
    Ok(RedrawEvent::WindowClose { grid: parse_u64(grid)? })
}

fn parse_msg_set_pos(args: Vec<Value>) -> Result<RedrawEvent> {
    let ([grid, row, scrolled, separator_character], [z_index, comp_index]) = extract_values_with_optional(args)?;
    Ok(RedrawEvent::MessageSetPosition {
        grid: parse_u64(grid)?,
        row: parse_u64(row)?,
        scrolled: parse_bool(scrolled)?,
        separator_character: parse_string(separator_character)?,
        z_index: z_index.map(parse_u64).transpose()?,
        comp_index: comp_index.map(parse_u64).transpose()?,
    })
}

fn parse_win_viewport(args: Vec<Value>) -> Result<RedrawEvent> {
    let ([grid, _window, top_line, bottom_line, current_line, current_column], [line_count, scroll_delta]) =
        extract_values_with_optional(args)?;
    Ok(RedrawEvent::WindowViewport {
        grid: parse_u64(grid)?,
        top_line: parse_f64(top_line)?,
        bottom_line: parse_f64(bottom_line)?,
        current_line: parse_f64(current_line)?,
        current_column: parse_f64(current_column)?,
        line_count: line_count.map(parse_f64).transpose()?,
        scroll_delta: scroll_delta.map(parse_f64).transpose()?,
    })
}

fn parse_win_viewport_margins(args: Vec<Value>) -> Result<RedrawEvent> {
    let [grid, _window, top, bottom, left, right] = extract_values(args)?;
    Ok(RedrawEvent::WindowViewportMargins {
        grid: parse_u64(grid)?,
        top: parse_u64(top)?,
        bottom: parse_u64(bottom)?,
        left: parse_u64(left)?,
        right: parse_u64(right)?,
    })
}

fn map_field(map: &[(Value, Value)], key: &str) -> Option<Value> {
    map.iter().find(|(k, _)| k.as_str() == Some(key)).map(|(_, v)| v.clone())
}

fn parse_tabline_update(args: Vec<Value>) -> Result<RedrawEvent> {
    let ([current_tab, tabs], [current_buffer, buffers]) = extract_values_with_optional(args)?;
    let mut tab_entries = Vec::new();
    for tab in parse_array(tabs)? {
        let map = parse_map(tab)?;
        let handle = map_field(&map, "tab").unwrap_or(Value::Nil);
        let name = map_field(&map, "name").and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
        tab_entries.push(TabEntry { handle, name });
    }
    let mut buffer_entries = Vec::new();
    if let Some(buffers) = buffers {
        for buffer in parse_array(buffers)? {
            let map = parse_map(buffer)?;
            let handle = map_field(&map, "buffer").unwrap_or(Value::Nil);
            let name = map_field(&map, "name").and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
            buffer_entries.push(BufferEntry { handle, name });
        }
    }
    Ok(RedrawEvent::TablineUpdate {
        current_tab,
        tabs: tab_entries,
        current_buffer: current_buffer.unwrap_or(Value::Nil),
        buffers: buffer_entries,
    })
}

fn parse_styled_content(line: Value) -> Result<StyledContent> {
    parse_array(line)?
        .into_iter()
        .map(|tuple| {
            let mut parts = parse_array(tuple)?;
            if parts.len() < 2 {
                return Err(ParseError::Format(format!("{parts:?}")));
            }
            let text = parse_string(parts.remove(1))?;
            let style_id = parse_u64(parts.remove(0))?;
            Ok((style_id, text))
        })
        .collect()
}

fn parse_cmdline_show(args: Vec<Value>) -> Result<RedrawEvent> {
    let ([content, position, first_character, prompt, indent, level], [_hl_id]) = extract_values_with_optional::<6, 1>(args)?;
    Ok(RedrawEvent::CommandLineShow {
        content: parse_styled_content(content)?,
        position: parse_u64(position)?,
        first_character: parse_string(first_character)?,
        prompt: parse_string(prompt)?,
        indent: parse_u64(indent)?,
        level: parse_u64(level)?,
    })
}

fn parse_cmdline_pos(args: Vec<Value>) -> Result<RedrawEvent> {
    let [position, level] = extract_values(args)?;
    Ok(RedrawEvent::CommandLinePosition { position: parse_u64(position)?, level: parse_u64(level)? })
}

fn parse_cmdline_special_char(args: Vec<Value>) -> Result<RedrawEvent> {
    let [character, shift, level] = extract_values(args)?;
    Ok(RedrawEvent::CommandLineSpecialCharacter {
        character: parse_string(character)?,
        shift: parse_bool(shift)?,
        level: parse_u64(level)?,
    })
}

fn parse_cmdline_block_show(args: Vec<Value>) -> Result<RedrawEvent> {
    let [lines] = extract_values(args)?;
    Ok(RedrawEvent::CommandLineBlockShow {
        lines: parse_array(lines)?.into_iter().map(parse_styled_content).collect::<Result<_>>()?,
    })
}

fn parse_cmdline_block_append(args: Vec<Value>) -> Result<RedrawEvent> {
    let [line] = extract_values(args)?;
    Ok(RedrawEvent::CommandLineBlockAppend { line: parse_styled_content(line)? })
}

fn parse_msg_show(args: Vec<Value>) -> Result<RedrawEvent> {
    let ([kind, content, replace_last], [_history, append, _id, _trigger]) = extract_values_with_optional(args)?;
    Ok(RedrawEvent::MessageShow {
        kind: MessageKind::parse(&parse_string(kind)?),
        content: parse_styled_content(content)?,
        replace_last: parse_bool(replace_last)?,
        append: append.map(parse_bool).transpose()?.unwrap_or(false),
    })
}

fn parse_msg_showmode(args: Vec<Value>) -> Result<RedrawEvent> {
    let [content] = extract_values(args)?;
    Ok(RedrawEvent::MessageShowMode { content: parse_styled_content(content)? })
}

fn parse_msg_showcmd(args: Vec<Value>) -> Result<RedrawEvent> {
    let [content] = extract_values(args)?;
    Ok(RedrawEvent::MessageShowCommand { content: parse_styled_content(content)? })
}

fn parse_msg_ruler(args: Vec<Value>) -> Result<RedrawEvent> {
    let [content] = extract_values(args)?;
    Ok(RedrawEvent::MessageRuler { content: parse_styled_content(content)? })
}

fn parse_msg_history_show(args: Vec<Value>) -> Result<RedrawEvent> {
    let ([entries], [_prev_cmd]) = extract_values_with_optional::<1, 1>(args)?;
    Ok(RedrawEvent::MessageHistoryShow {
        entries: parse_array(entries)?
            .into_iter()
            .map(|entry| {
                let [kind, content] = extract_values(parse_array(entry)?)?;
                Ok((MessageKind::parse(&parse_string(kind)?), parse_styled_content(content)?))
            })
            .collect::<Result<_>>()?,
    })
}

fn parse_popupmenu_show(args: Vec<Value>) -> Result<RedrawEvent> {
    let [items, selected, row, col, grid] = extract_values(args)?;
    let items = parse_array(items)?
        .into_iter()
        .map(|item| parse_array(item)?.into_iter().map(parse_string).collect::<Result<Vec<_>>>())
        .collect::<Result<Vec<_>>>()?;
    Ok(RedrawEvent::PopupmenuShow {
        items,
        selected: parse_i64(selected)?,
        row: parse_u64(row)?,
        col: parse_u64(col)?,
        grid: parse_u64(grid)?,
    })
}

fn parse_popupmenu_select(args: Vec<Value>) -> Result<RedrawEvent> {
    let [selected] = extract_values(args)?;
    Ok(RedrawEvent::PopupmenuSelect { selected: parse_i64(selected)? })
}

/// Parse one `["event_name", [args...], [args...], ...]` entry of a `redraw` notification
/// into zero or more events. Unknown events are skipped, not errors.
pub fn parse_redraw_event(event_value: Value) -> Result<Vec<RedrawEvent>> {
    let mut contents = parse_array(event_value)?.into_iter();
    let event_name = contents.next().ok_or_else(|| ParseError::Format("empty event".into())).and_then(parse_string)?;
    let mut parsed = Vec::with_capacity(contents.len());
    for event in contents {
        let params = parse_array(event)?;
        let params_copy = params.clone();
        let possible = match event_name.as_str() {
            "set_title" => Some(parse_set_title(params)),
            "restart" => Some(parse_restart(params)),
            "mode_info_set" => Some(parse_mode_info_set(params)),
            "option_set" => Some(parse_option_set(params)),
            "mode_change" => Some(parse_mode_change(params)),
            "mouse_on" => Some(Ok(RedrawEvent::MouseOn)),
            "mouse_off" => Some(Ok(RedrawEvent::MouseOff)),
            "busy_start" => Some(Ok(RedrawEvent::BusyStart)),
            "busy_stop" => Some(Ok(RedrawEvent::BusyStop)),
            "flush" => Some(Ok(RedrawEvent::Flush)),
            "grid_resize" => Some(parse_grid_resize(params)),
            "default_colors_set" => Some(parse_default_colors(params)),
            "hl_attr_define" => Some(parse_hl_attr_define(params)),
            "hl_group_set" => Some(parse_hl_group_set(params)),
            "grid_line" => Some(parse_grid_line(params)),
            "grid_clear" => Some(parse_grid_clear(params)),
            "grid_destroy" => Some(parse_grid_destroy(params)),
            "grid_cursor_goto" => Some(parse_grid_cursor_goto(params)),
            "grid_scroll" => Some(parse_grid_scroll(params)),
            "win_pos" => Some(parse_win_pos(params)),
            "win_float_pos" => Some(parse_win_float_pos(params)),
            "win_external_pos" => Some(parse_win_external_pos(params)),
            "win_hide" => Some(parse_win_hide(params)),
            "win_close" => Some(parse_win_close(params)),
            "msg_set_pos" => Some(parse_msg_set_pos(params)),
            "win_viewport" => Some(parse_win_viewport(params)),
            "win_viewport_margins" => Some(parse_win_viewport_margins(params)),
            "tabline_update" => Some(parse_tabline_update(params)),
            "cmdline_show" => Some(parse_cmdline_show(params)),
            "cmdline_pos" => Some(parse_cmdline_pos(params)),
            "cmdline_special_char" => Some(parse_cmdline_special_char(params)),
            "cmdline_hide" => Some(Ok(RedrawEvent::CommandLineHide)),
            "cmdline_block_show" => Some(parse_cmdline_block_show(params)),
            "cmdline_block_append" => Some(parse_cmdline_block_append(params)),
            "cmdline_block_hide" => Some(Ok(RedrawEvent::CommandLineBlockHide)),
            "msg_show" => Some(parse_msg_show(params)),
            "msg_clear" => Some(Ok(RedrawEvent::MessageClear)),
            "msg_showmode" => Some(parse_msg_showmode(params)),
            "msg_showcmd" => Some(parse_msg_showcmd(params)),
            "msg_ruler" => Some(parse_msg_ruler(params)),
            "msg_history_show" => Some(parse_msg_history_show(params)),
            "popupmenu_show" => Some(parse_popupmenu_show(params)),
            "popupmenu_select" => Some(parse_popupmenu_select(params)),
            "popupmenu_hide" => Some(Ok(RedrawEvent::PopupmenuHide)),
            "suspend" => Some(Ok(RedrawEvent::Suspend)),
            _ => None,
        };
        match possible {
            Some(Ok(event)) => parsed.push(event),
            Some(Err(err)) => {
                return Err(ParseError::Format(format!("for event '{event_name}' - {params_copy:?} - {err}")));
            }
            None => {}
        }
    }
    Ok(parsed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grid_line_parses_repeat_and_inherited_highlight() {
        let v = Value::Array(vec![
            Value::from("grid_line"),
            Value::Array(vec![
                Value::from(2),
                Value::from(0),
                Value::from(0),
                Value::Array(vec![
                    Value::Array(vec![Value::from("a"), Value::from(3)]),
                    Value::Array(vec![Value::from(" "), Value::from(0), Value::from(5)]),
                    Value::Array(vec![Value::from("b")]),
                ]),
                Value::from(false),
            ]),
        ]);
        let events = parse_redraw_event(v).unwrap();
        match &events[0] {
            RedrawEvent::GridLine { grid, cells, .. } => {
                assert_eq!(*grid, 2);
                assert_eq!(cells[0].highlight_id, Some(3));
                assert_eq!(cells[1].repeat, Some(5));
                assert_eq!(cells[2].highlight_id, None);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn unknown_events_are_skipped() {
        let v = Value::Array(vec![Value::from("chdir"), Value::Array(vec![Value::from("/tmp")])]);
        assert!(parse_redraw_event(v).unwrap().is_empty());
    }

    #[test]
    fn msg_show_tolerates_old_and_new_arity() {
        let short = parse_msg_show(vec![Value::from("echo"), Value::Array(vec![]), Value::from(false)]).unwrap();
        assert!(matches!(short, RedrawEvent::MessageShow { append: false, .. }));
        let long = parse_msg_show(vec![
            Value::from("echo"),
            Value::Array(vec![]),
            Value::from(false),
            Value::from(true),
            Value::from(true),
            Value::Nil,
            Value::from(""),
        ])
        .unwrap();
        assert!(matches!(long, RedrawEvent::MessageShow { append: true, .. }));
    }
}
