//! Background work for the chrome: ripgrep, git, directory listings. Each task runs on its
//! own thread and reports back through the event loop; the shell never blocks on them.

use std::{path::PathBuf, process::Command};

#[derive(Clone, Debug)]
pub enum Task {
    Search { generation: u64, cwd: PathBuf, query: String, args: Vec<String> },
    GitStatus { cwd: PathBuf },
    GitStage { cwd: PathBuf, path: String, stage: bool },
    GitCommit { cwd: PathBuf, message: String },
    ListFiles { cwd: PathBuf },
}

#[derive(Clone, Debug)]
pub struct SearchHit {
    pub path: String,
    pub file: String,
    pub line: u64,
    pub col: u64,
    pub text: String,
}

#[derive(Clone, Debug, Default)]
pub struct GitStatus {
    pub branch: String,
    pub staged: Vec<GitEntry>,
    pub unstaged: Vec<GitEntry>,
    pub error: Option<String>,
}

#[derive(Clone, Debug)]
pub struct GitEntry {
    pub path: String,
    /// One letter: M, A, D, R, ?, etc.
    pub status: char,
}

#[derive(Clone, Debug)]
pub enum TaskResult {
    Search { generation: u64, hits: Vec<SearchHit>, error: Option<String> },
    GitStatus(GitStatus),
    GitDone { error: Option<String> },
    Files { cwd: PathBuf, files: Vec<String> },
}

fn command(program: &str, cwd: &PathBuf) -> Command {
    let mut cmd = Command::new(program);
    cmd.current_dir(cwd);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    cmd
}

pub fn run(task: Task) -> TaskResult {
    match task {
        Task::Search { generation, cwd, query, args } => {
            if query.trim().is_empty() {
                return TaskResult::Search { generation, hits: Vec::new(), error: None };
            }
            let output = command("rg", &cwd)
                .args(["--vimgrep", "--no-heading", "--color", "never", "--smart-case", "--max-count", "50", "--max-columns", "300"])
                .args(&args)
                .args(["-e", &query, "."])
                .output();
            match output {
                Ok(out) => {
                    let text = String::from_utf8_lossy(&out.stdout);
                    let mut hits = Vec::new();
                    for line in text.lines().take(2000) {
                        // path:line:col:text  (path may contain ':' on Windows after the drive)
                        let rest = line.strip_prefix(".\\").or_else(|| line.strip_prefix("./")).unwrap_or(line);
                        let mut parts = rest.splitn(4, ':');
                        let (Some(path), Some(l), Some(c), Some(t)) = (parts.next(), parts.next(), parts.next(), parts.next()) else { continue };
                        let (Ok(l), Ok(c)) = (l.parse::<u64>(), c.parse::<u64>()) else { continue };
                        hits.push(SearchHit {
                            path: cwd.join(path).to_string_lossy().to_string(),
                            file: path.replace('\\', "/"),
                            line: l,
                            col: c,
                            text: t.trim().to_string(),
                        });
                    }
                    let error = if !out.status.success() && hits.is_empty() && !out.stderr.is_empty() {
                        Some(String::from_utf8_lossy(&out.stderr).trim().to_string())
                    } else {
                        None
                    };
                    TaskResult::Search { generation, hits, error }
                }
                Err(e) => TaskResult::Search { generation, hits: Vec::new(), error: Some(format!("ripgrep (rg) not found: {e}")) },
            }
        }
        Task::GitStatus { cwd } => TaskResult::GitStatus(git_status(&cwd)),
        Task::GitStage { cwd, path, stage } => {
            let output = if stage {
                command("git", &cwd).args(["add", "--", &path]).output()
            } else {
                command("git", &cwd).args(["restore", "--staged", "--", &path]).output()
            };
            TaskResult::GitDone { error: git_error(output) }
        }
        Task::GitCommit { cwd, message } => {
            let output = command("git", &cwd).args(["commit", "-m", &message]).output();
            TaskResult::GitDone { error: git_error(output) }
        }
        Task::ListFiles { cwd } => {
            let mut files = Vec::new();
            for entry in walkdir::WalkDir::new(&cwd)
                .into_iter()
                .filter_entry(|e| {
                    let name = e.file_name().to_string_lossy();
                    !(name == ".git" || name == "node_modules" || name == "target" || name == "__pycache__")
                })
                .flatten()
                .take(50_000)
            {
                if entry.file_type().is_file() {
                    if let Ok(rel) = entry.path().strip_prefix(&cwd) {
                        files.push(rel.to_string_lossy().replace('\\', "/"));
                    }
                }
            }
            TaskResult::Files { cwd, files }
        }
    }
}

fn git_error(output: std::io::Result<std::process::Output>) -> Option<String> {
    match output {
        Ok(out) if out.status.success() => None,
        Ok(out) => Some(String::from_utf8_lossy(&out.stderr).trim().to_string()),
        Err(e) => Some(format!("git not found: {e}")),
    }
}

fn git_status(cwd: &PathBuf) -> GitStatus {
    let output = command("git", cwd).args(["status", "--porcelain=v1", "-b", "--untracked-files=all"]).output();
    let out = match output {
        Ok(o) if o.status.success() => o,
        Ok(o) => return GitStatus { error: Some(String::from_utf8_lossy(&o.stderr).trim().to_string()), ..Default::default() },
        Err(e) => return GitStatus { error: Some(format!("git not found: {e}")), ..Default::default() },
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut status = GitStatus::default();
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("## ") {
            status.branch = rest.split("...").next().unwrap_or(rest).to_string();
            continue;
        }
        if line.len() < 4 {
            continue;
        }
        let x = line.as_bytes()[0] as char;
        let y = line.as_bytes()[1] as char;
        let path = line[3..].to_string();
        if x == '?' {
            status.unstaged.push(GitEntry { path: path.clone(), status: '?' });
            continue;
        }
        if x != ' ' {
            status.staged.push(GitEntry { path: path.clone(), status: x });
        }
        if y != ' ' {
            status.unstaged.push(GitEntry { path, status: y });
        }
    }
    status
}

/// Subsequence fuzzy match, as the mockup does it: lower score is better; None if no match.
pub fn fuzzy(query: &str, target: &str) -> Option<(i32, Vec<usize>)> {
    if query.is_empty() {
        return Some((0, Vec::new()));
    }
    let q: Vec<char> = query.to_lowercase().chars().collect();
    let t: Vec<char> = target.to_lowercase().chars().collect();
    if let Some(pos) = target.to_lowercase().find(&query.to_lowercase()) {
        let start = target[..pos].chars().count();
        return Some((start as i32, (start..start + q.len()).collect()));
    }
    // Subsequence: try every place the first character occurs and keep the tightest match,
    // so "nvsask" lands on "nvs/ask" rather than the n of "runtime".
    let mut best: Option<(i32, Vec<usize>)> = None;
    for start in 0..t.len() {
        if t[start] != q[0] {
            continue;
        }
        let mut hits = Vec::with_capacity(q.len());
        let mut qi = 0;
        for (ti, ch) in t.iter().enumerate().skip(start) {
            if qi < q.len() && *ch == q[qi] {
                hits.push(ti);
                qi += 1;
            }
        }
        if qi < q.len() {
            break; // no later start can complete the match either
        }
        let spread = (hits[hits.len() - 1] - hits[0]) as i32;
        let score = 100 + spread * 4 + start as i32;
        if best.as_ref().map(|b| score < b.0).unwrap_or(true) {
            best = Some((score, hits));
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuzzy_prefers_substrings_then_tight_subsequences() {
        assert_eq!(fuzzy("ask", "runtime/lua/nvs/ask.lua").map(|m| m.0), Some(16));
        let (a, _) = fuzzy("nvsask", "runtime/lua/nvs/ask.lua").unwrap();
        let (b, _) = fuzzy("nvsask", "nvs/x/y/z/ask").unwrap();
        assert!(a < b);
        assert!(fuzzy("zzz", "abc").is_none());
    }
}
