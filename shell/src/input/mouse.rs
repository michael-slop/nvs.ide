//! winit mouse events to `nvim_input_mouse`. A trimmed port of Neovide's mouse_manager.rs
//! (MIT, LICENSE-NEOVIDE): hit-test the window under the pointer using the last frame's
//! layout, keep drags on the window they started in, accumulate wheel deltas into whole cells.

use winit::event::{ElementState, MouseButton, MouseScrollDelta, WindowEvent};

use crate::bridge::{CommandSender, SerialCommand};

/// One window's pixel rectangle, in draw order (later entries are on top).
#[derive(Clone, Debug)]
pub struct WindowRegion {
    pub id: u64,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub cols: u32,
    pub rows: u32,
}

impl WindowRegion {
    fn contains(&self, px: f32, py: f32) -> bool {
        px >= self.x && py >= self.y && px < self.x + self.width && py < self.y + self.height
    }

    fn cell_at(&self, px: f32, py: f32, cell: (f32, f32)) -> (u32, u32) {
        let col = (((px - self.x) / cell.0).floor().max(0.0) as u32).min(self.cols.max(1) - 1);
        let row = (((py - self.y) / cell.1).floor().max(0.0) as u32).min(self.rows.max(1) - 1);
        (col, row)
    }
}

fn button_name(button: MouseButton) -> Option<&'static str> {
    match button {
        MouseButton::Left => Some("left"),
        MouseButton::Right => Some("right"),
        MouseButton::Middle => Some("middle"),
        MouseButton::Back => Some("x1"),
        MouseButton::Forward => Some("x2"),
        _ => None,
    }
}

#[derive(Default)]
pub struct MouseManager {
    pub position: (f32, f32),
    drag: Option<(MouseButton, u64)>,
    grid_position: (u32, u32),
    has_moved: bool,
    scroll_accumulator: (f32, f32),
    pub enabled: bool,
}

impl MouseManager {
    pub fn new() -> Self {
        Self { enabled: true, ..Default::default() }
    }

    fn region_under<'a>(&self, regions: &'a [WindowRegion]) -> Option<&'a WindowRegion> {
        regions.iter().rev().find(|r| r.contains(self.position.0, self.position.1))
    }

    /// Returns true if the event was a mouse event (consumed).
    pub fn handle_event(&mut self, event: &WindowEvent, regions: &[WindowRegion], cell: (f32, f32), modifiers: &str, sender: &CommandSender) -> bool {
        match event {
            WindowEvent::CursorMoved { position, .. } => {
                self.position = (position.x as f32, position.y as f32);
                let region = match self.drag {
                    Some((_, id)) => regions.iter().find(|r| r.id == id),
                    None => self.region_under(regions),
                };
                if let Some(region) = region {
                    let previous = self.grid_position;
                    self.grid_position = region.cell_at(self.position.0, self.position.1, cell);
                    if self.grid_position != previous {
                        if let Some((button, _)) = self.drag {
                            if let Some(name) = button_name(button) {
                                sender.send(SerialCommand::Drag {
                                    button: name.into(),
                                    grid_id: region.id,
                                    position: self.grid_position,
                                    modifier_string: modifiers.into(),
                                });
                                self.has_moved = true;
                            }
                        }
                    }
                }
                true
            }
            WindowEvent::MouseInput { state, button, .. } => {
                if !self.enabled {
                    return true;
                }
                let Some(name) = button_name(*button) else { return true };
                let down = *state == ElementState::Pressed;
                let region = match (down, self.drag) {
                    (false, Some((_, id))) => regions.iter().find(|r| r.id == id),
                    _ => self.region_under(regions),
                };
                if let Some(region) = region {
                    let position = if !down && self.has_moved { self.grid_position } else { region.cell_at(self.position.0, self.position.1, cell) };
                    sender.send(SerialCommand::MouseButton {
                        button: name.into(),
                        action: if down { "press" } else { "release" }.into(),
                        grid_id: region.id,
                        position,
                        modifier_string: modifiers.into(),
                    });
                    self.drag = if down { Some((*button, region.id)) } else { None };
                } else {
                    self.drag = None;
                }
                if self.drag.is_none() {
                    self.has_moved = false;
                }
                true
            }
            WindowEvent::MouseWheel { delta, .. } => {
                if !self.enabled {
                    return true;
                }
                let (dx, dy) = match delta {
                    MouseScrollDelta::LineDelta(x, y) => (*x, *y),
                    MouseScrollDelta::PixelDelta(p) => (p.x as f32 / cell.0, p.y as f32 / cell.1),
                };
                let region = self.region_under(regions);
                let grid_id = region.map(|r| r.id).unwrap_or(0);
                let position = region.map(|r| r.cell_at(self.position.0, self.position.1, cell)).unwrap_or((0, 0));
                let before = (self.scroll_accumulator.0.floor() as i32, self.scroll_accumulator.1.floor() as i32);
                self.scroll_accumulator.0 += dx;
                self.scroll_accumulator.1 += dy;
                let after = (self.scroll_accumulator.0.floor() as i32, self.scroll_accumulator.1.floor() as i32);
                let vertical = after.1 - before.1;
                if vertical != 0 {
                    sender.send(SerialCommand::Scroll {
                        direction: if vertical > 0 { "up" } else { "down" }.into(),
                        grid_id,
                        position,
                        count: vertical.unsigned_abs(),
                        modifier_string: modifiers.into(),
                    });
                }
                let horizontal = after.0 - before.0;
                if horizontal != 0 {
                    sender.send(SerialCommand::Scroll {
                        direction: if horizontal > 0 { "right" } else { "left" }.into(),
                        grid_id,
                        position,
                        count: horizontal.unsigned_abs(),
                        modifier_string: modifiers.into(),
                    });
                }
                true
            }
            _ => false,
        }
    }
}
