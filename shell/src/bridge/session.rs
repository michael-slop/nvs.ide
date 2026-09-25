//! Spawning `nvim --embed` and wiring its stdio into nvim-rs.
//!
//! Ported from Neovide's src/bridge/session.rs (MIT, LICENSE-NEOVIDE). The Windows part
//! matters: tokio's process pipes are overlapped handles, and reading them through tokio's
//! `Child` can hit a synchronous-read path that Rust deliberately aborts on
//! (rust-lang/rust#81357). Neovide spawns with `std::process::Command`, takes the raw pipe
//! handles and wraps them in `NamedPipeServer`, which supports overlapped I/O. We do the same.

#[cfg(windows)]
use std::process::Child;
use std::{
    io::{Error, Result},
    process::Stdio,
};

use anyhow::Context;
use nvim_rs::{error::LoopError, neovim::Neovim, Handler};
#[cfg(not(windows))]
use tokio::process::Child;
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncWrite, BufReader},
    process::Command,
    spawn,
    task::JoinHandle,
};
use tokio_util::compat::{TokioAsyncReadCompatExt, TokioAsyncWriteCompatExt};

pub type NeovimWriter = Box<dyn futures::AsyncWrite + Send + Unpin + 'static>;

type BoxedReader = Box<dyn AsyncRead + Send + Unpin + 'static>;
type BoxedWriter = Box<dyn AsyncWrite + Send + Unpin + 'static>;

pub struct NeovimSession {
    pub neovim: Neovim<NeovimWriter>,
    pub io_handle: JoinHandle<std::result::Result<(), Box<LoopError>>>,
    pub process: Option<Child>,
    pub stderr_task: Option<JoinHandle<Vec<String>>>,
}

impl NeovimSession {
    pub async fn spawn(cmd: Command, handler: impl Handler<Writer = NeovimWriter>) -> anyhow::Result<Self> {
        let (reader, writer, stderr_reader, process) = spawn_process(cmd).await?;
        let stderr_task = stderr_reader.map(|reader| {
            tokio::spawn(async move {
                let mut lines = Vec::new();
                let mut reader = BufReader::new(reader).lines();
                while let Some(line) = reader.next_line().await.unwrap_or_default() {
                    log::warn!("nvim stderr: {line}");
                    lines.push(line);
                }
                lines
            })
        });
        // Handshake message: nvim-rs requires a length outside 20..=31 (neovim/neovim#32784).
        let handshake_message = "NvsShellToNeovimHandshakeMessage";
        let result = Neovim::<NeovimWriter>::handshake(reader.compat(), Box::new(writer.compat_write()), handler, handshake_message).await;
        match result {
            Err(err) => {
                if let Some(stderr_task) = stderr_task {
                    let stderr = "nvim stderr:\n".to_owned() + &stderr_task.await?.join("\n");
                    Err(err).context(stderr)
                } else {
                    Err(err.into())
                }
            }
            Ok((neovim, io)) => Ok(Self { neovim, io_handle: spawn(io), process, stderr_task }),
        }
    }
}

async fn spawn_process(
    #[cfg(not(windows))] mut cmd: Command,
    #[cfg(windows)] cmd: Command,
) -> Result<(BoxedReader, BoxedWriter, Option<BoxedReader>, Option<Child>)> {
    log::debug!("starting neovim with: {cmd:?}");

    #[cfg(windows)]
    let mut cmd = cmd.into_std();

    let mut child = cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
    let reader_inner = child.stdout.take().ok_or_else(|| Error::other("can't open nvim stdout"))?;
    let writer_inner = child.stdin.take().ok_or_else(|| Error::other("can't open nvim stdin"))?;
    let stderr_inner = child.stderr.take().ok_or_else(|| Error::other("can't open nvim stderr"))?;

    let reader: BoxedReader;
    let writer: BoxedWriter;
    let stderr_reader: BoxedReader;

    #[cfg(not(windows))]
    {
        reader = Box::new(reader_inner);
        writer = Box::new(writer_inner);
        stderr_reader = Box::new(stderr_inner);
    }

    #[cfg(windows)]
    {
        use std::os::windows::io::IntoRawHandle;
        use tokio::net::windows::named_pipe::NamedPipeServer;
        reader = Box::new(unsafe { NamedPipeServer::from_raw_handle(reader_inner.into_raw_handle()) }?);
        writer = Box::new(unsafe { NamedPipeServer::from_raw_handle(writer_inner.into_raw_handle()) }?);
        stderr_reader = Box::new(unsafe { NamedPipeServer::from_raw_handle(stderr_inner.into_raw_handle()) }?);
    }

    Ok((reader, writer, Some(stderr_reader), Some(child)))
}
