//! Headless end-to-end test: spawn `nvim --embed --clean`, attach, receive a first flush with
//! text on grid 1, type into it, and quit cleanly. Needs `nvim` on PATH.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nvs_shell::bridge::{Bridge, BridgeConfig, BridgeSink, ParallelCommand, RedrawEvent, SerialCommand};
use nvs_shell::editor::{Editor, EditorNotice, Frame, FrameSink};
use rmpv::Value;

#[derive(Clone, Default)]
struct TestSink {
    inner: Arc<Mutex<Inner>>,
}

#[derive(Default)]
struct Inner {
    editor: Editor,
    frames: Vec<Arc<Frame>>,
    quit_code: Option<i32>,
    exited: bool,
}

// FrameSink requires 'static, so the collector owns its buffer and is drained after each batch.
struct OwnedCollector(Vec<Arc<Frame>>);
impl FrameSink for OwnedCollector {
    fn frame(&mut self, frame: Arc<Frame>) {
        self.0.push(frame);
    }
    fn notice(&mut self, _n: EditorNotice) {}
}

impl BridgeSink for TestSink {
    fn redraw(&self, events: Vec<RedrawEvent>) {
        let mut inner = self.inner.lock().unwrap();
        let mut collector = OwnedCollector(Vec::new());
        for event in events {
            inner.editor.handle_redraw_event(event, &mut collector);
        }
        inner.frames.extend(collector.0);
    }
    fn nvs(&self, _event: String, _payload: Value) {}
    fn quit_requested(&self, code: i32) {
        self.inner.lock().unwrap().quit_code = Some(code);
    }
    fn exited(&self) {
        self.inner.lock().unwrap().exited = true;
    }
}

fn wait_until(deadline: Duration, mut pred: impl FnMut() -> bool) -> bool {
    let start = Instant::now();
    while start.elapsed() < deadline {
        if pred() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    pred()
}

fn frame_text(frame: &Frame, grid: u64, row: usize) -> String {
    frame
        .windows
        .iter()
        .find(|w| w.id == grid)
        .and_then(|w| w.lines.get(row))
        .map(|line| line.fragments.iter().flat_map(|f| f.words.iter().map(|w| w.text.clone())).collect::<Vec<_>>().join(" "))
        .unwrap_or_default()
}

#[test]
fn attaches_receives_flush_types_and_quits() {
    let sink = TestSink::default();
    let config = BridgeConfig {
        nvim_args: vec!["--clean".into()],
        app_name: None,
        grid: (60, 12),
        ..Default::default()
    };
    let t0 = Instant::now();
    let bridge = Bridge::start(config, sink.clone()).expect("bridge start");
    let attach_ms = t0.elapsed().as_millis();
    assert!(bridge.info.version.at_least(0, 10, 0), "nvim {}", bridge.info.version);
    assert_eq!(bridge.info.channel, 1, "an embedded UI is channel 1");

    // First flush: the window grid exists at the requested size.
    assert!(wait_until(Duration::from_secs(10), || !sink.inner.lock().unwrap().frames.is_empty()), "no flush within 10 s");
    let first_flush_ms = t0.elapsed().as_millis();
    {
        let inner = sink.inner.lock().unwrap();
        let frame = inner.frames.last().unwrap();
        assert_eq!(frame.grid_size, (60, 12));
        assert!(frame.windows.iter().any(|w| w.id == 1));
        // Grid 2 is the first window with multigrid.
        assert!(frame.windows.iter().any(|w| w.id == 2), "no window grid in {:?}", frame.windows.iter().map(|w| w.id).collect::<Vec<_>>());
    }

    // Type a line in insert mode and check it appears on the window grid.
    bridge.send(SerialCommand::Keyboard("ihello nvs<Esc>".into()));
    assert!(
        wait_until(Duration::from_secs(5), || {
            let inner = sink.inner.lock().unwrap();
            inner.frames.last().map(|f| frame_text(f, 2, 0).contains("hello")).unwrap_or(false)
        }),
        "typed text never showed up"
    );
    let frame = sink.inner.lock().unwrap().frames.last().unwrap().clone();
    assert!(frame_text(&frame, 2, 0).contains("nvs"), "row 0 = {:?}", frame_text(&frame, 2, 0));
    assert_eq!(frame.cursor.parent_grid, 2);

    // Resize and expect the grid to follow.
    bridge.send(ParallelCommand::Resize { width: 80, height: 20 });
    assert!(
        wait_until(Duration::from_secs(5), || sink.inner.lock().unwrap().frames.last().map(|f| f.grid_size == (80, 20)).unwrap_or(false)),
        "resize never applied"
    );

    // Quit without saving; VimLeavePre reports the exit code, then the process exits.
    bridge.send(ParallelCommand::Quit { confirm: false });
    assert!(wait_until(Duration::from_secs(5), || sink.inner.lock().unwrap().exited), "nvim did not exit");
    assert_eq!(sink.inner.lock().unwrap().quit_code, Some(0));
    eprintln!("attach {attach_ms} ms, first flush {first_flush_ms} ms");
    bridge.shutdown(Duration::from_millis(500));
}
