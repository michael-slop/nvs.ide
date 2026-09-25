//! Cursor blink state, from Neovim's blinkwait/blinkon/blinkoff.
//! Ported from Neovide's src/renderer/cursor_renderer/blink.rs (MIT, LICENSE-NEOVIDE).

use std::time::{Duration, Instant};

use crate::editor::Cursor;

#[derive(Debug, PartialEq, Clone, Copy)]
enum BlinkState {
    Waiting,
    On,
    Off,
}

/// What the app should do after updating the blink: redraw now, wait until a deadline, or
/// nothing (static cursor).
#[derive(Debug, PartialEq, Clone, Copy)]
pub enum BlinkAction {
    Wait,
    Deadline(Instant),
    Immediately,
}

pub struct BlinkStatus {
    state: BlinkState,
    transition_time: Instant,
    current: Option<Cursor>,
}

impl Default for BlinkStatus {
    fn default() -> Self {
        Self::new()
    }
}

impl BlinkStatus {
    pub fn new() -> Self {
        Self { state: BlinkState::Waiting, transition_time: Instant::now(), current: None }
    }

    fn delay(&self) -> Duration {
        let ms = match (&self.current, self.state) {
            (Some(c), BlinkState::Waiting) => c.blinkwait.unwrap_or(0),
            (Some(c), BlinkState::Off) => c.blinkoff.unwrap_or(0),
            (Some(c), BlinkState::On) => c.blinkon.unwrap_or(0),
            (None, _) => 0,
        };
        Duration::from_millis(ms)
    }

    /// Update with the cursor from the latest frame. A changed cursor restarts the cycle.
    pub fn update(&mut self, cursor: &Cursor) -> BlinkAction {
        let now = Instant::now();
        let changed = match &self.current {
            Some(c) => {
                c.grid_position != cursor.grid_position
                    || c.parent_grid != cursor.parent_grid
                    || c.blinkwait != cursor.blinkwait
                    || c.blinkon != cursor.blinkon
                    || c.blinkoff != cursor.blinkoff
                    || c.shape != cursor.shape
            }
            None => true,
        };
        if changed {
            self.current = Some(cursor.clone());
            self.state = if matches!(cursor.blinkwait, Some(w) if w > 0) { BlinkState::Waiting } else { BlinkState::On };
            self.transition_time = now + self.delay();
        }
        let current = self.current.as_ref().unwrap();
        if current.is_static() {
            self.state = BlinkState::Waiting;
            return BlinkAction::Wait;
        }
        if self.transition_time <= now {
            self.state = match self.state {
                BlinkState::Waiting => BlinkState::On,
                BlinkState::On => BlinkState::Off,
                BlinkState::Off => BlinkState::On,
            };
            self.transition_time += self.delay();
            if self.transition_time <= now {
                self.transition_time = now + self.delay();
            }
            return BlinkAction::Immediately;
        }
        BlinkAction::Deadline(self.transition_time)
    }

    pub fn visible(&self) -> bool {
        self.state != BlinkState::Off
    }
}
