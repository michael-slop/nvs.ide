//! nvs.ide shell: the native window around `nvim --embed`.
//!
//! Layout follows the design in docs/design.md and the review of 2026-09-25:
//! - `bridge`: spawning Neovim, the msgpack-RPC connection, the redraw-event parser and the
//!   commands that go back (keys, mouse, resize, quit). Ported from Neovide (MIT, see
//!   LICENSE-NEOVIDE) with skia removed.
//! - `editor`: the grid/window model that turns redraw events into a frame snapshot the
//!   renderer can draw. Also ported from Neovide.
//! - `font`: font loading, system-font fallback and swash shaping into glyph runs.
//! - `renderer`: the wgpu cell renderer that draws both Neovim's grids and the workbench chrome.
//! - `input`: winit key and mouse events to Neovim input strings (Neovide's rules).
//! - `app`: the winit application that ties it together.

pub mod app;
pub mod bridge;
pub mod color;
pub mod editor;
pub mod font;
pub mod input;
pub mod renderer;
pub mod timing;
pub mod ui;
pub mod workbench;
