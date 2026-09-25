//! The native file tree for the sidebar.

use std::path::{Path, PathBuf};
use std::sync::{LazyLock, RwLock};

use crate::ui::widgets::ListState;

/// Names hidden from the tree: the "Hide from the explorer and search" setting.
static HIDDEN: LazyLock<RwLock<Vec<String>>> = LazyLock::new(|| RwLock::new([".git", "node_modules", "target", "__pycache__", ".DS_Store"].iter().map(|s| s.to_string()).collect()));

/// Replace the hidden-name list. Returns true when it changed (the tree needs a refresh).
pub fn set_hidden(names: Vec<String>) -> bool {
    let mut hidden = HIDDEN.write().unwrap();
    if *hidden == names {
        return false;
    }
    *hidden = names;
    true
}

fn is_hidden(name: &str) -> bool {
    HIDDEN.read().map(|h| h.iter().any(|n| n == name)).unwrap_or(false)
}

#[derive(Clone, Debug)]
pub struct Node {
    pub path: PathBuf,
    pub name: String,
    pub is_dir: bool,
    pub depth: usize,
    pub expanded: bool,
    pub loaded: bool,
    pub children: Vec<Node>,
}

impl Node {
    fn load_children(&mut self) {
        if self.loaded || !self.is_dir {
            return;
        }
        self.loaded = true;
        let mut dirs = Vec::new();
        let mut files = Vec::new();
        if let Ok(read) = std::fs::read_dir(&self.path) {
            for entry in read.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if is_hidden(&name) {
                    continue;
                }
                let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
                let node = Node { path: entry.path(), name, is_dir, depth: self.depth + 1, expanded: false, loaded: false, children: Vec::new() };
                if is_dir {
                    dirs.push(node);
                } else {
                    files.push(node);
                }
            }
        }
        let key = |n: &Node| n.name.to_lowercase();
        dirs.sort_by_key(key);
        files.sort_by_key(key);
        self.children = dirs;
        self.children.extend(files);
    }
}

pub struct Explorer {
    pub root: Node,
    pub list: ListState,
    /// Flattened visible rows: indices into the tree, rebuilt on every change.
    visible: Vec<Vec<usize>>,
}

impl Explorer {
    pub fn new(root: &Path) -> Self {
        let name = root.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| root.display().to_string());
        let mut root_node = Node { path: root.to_path_buf(), name, is_dir: true, depth: 0, expanded: true, loaded: false, children: Vec::new() };
        root_node.load_children();
        let mut e = Explorer { root: root_node, list: ListState::default(), visible: Vec::new() };
        e.rebuild();
        e
    }

    pub fn root_path(&self) -> &Path {
        &self.root.path
    }

    pub fn set_root(&mut self, root: &Path) {
        if self.root.path == root {
            return;
        }
        *self = Explorer::new(root);
    }

    /// Re-read every expanded directory (after a git operation or an external change).
    pub fn refresh(&mut self) {
        fn reload(node: &mut Node) {
            if !node.is_dir || !node.loaded {
                return;
            }
            let expanded: Vec<PathBuf> = node.children.iter().filter(|c| c.expanded).map(|c| c.path.clone()).collect();
            node.loaded = false;
            node.children.clear();
            node.load_children();
            for child in &mut node.children {
                if expanded.contains(&child.path) {
                    child.expanded = true;
                    reload(child);
                }
            }
        }
        reload(&mut self.root);
        self.rebuild();
    }

    fn rebuild(&mut self) {
        fn walk(node: &Node, path: &mut Vec<usize>, out: &mut Vec<Vec<usize>>) {
            out.push(path.clone());
            if node.is_dir && node.expanded {
                for (i, child) in node.children.iter().enumerate() {
                    path.push(i);
                    walk(child, path, out);
                    path.pop();
                }
            }
        }
        let mut out = Vec::new();
        walk(&self.root, &mut Vec::new(), &mut out);
        self.visible = out;
        if self.list.selected >= self.visible.len() {
            self.list.selected = self.visible.len().saturating_sub(1);
        }
    }

    fn node(&self, index: &[usize]) -> &Node {
        let mut n = &self.root;
        for &i in index {
            n = &n.children[i];
        }
        n
    }

    fn node_mut(&mut self, index: &[usize]) -> &mut Node {
        let mut n = &mut self.root;
        for &i in index {
            n = &mut n.children[i];
        }
        n
    }

    pub fn rows(&self) -> Vec<&Node> {
        self.visible.iter().map(|p| self.node(p)).collect()
    }

    pub fn len(&self) -> usize {
        self.visible.len()
    }

    pub fn is_empty(&self) -> bool {
        self.visible.is_empty()
    }

    /// Enter/l/click on row `i`: expand a directory or return the file to open.
    pub fn activate(&mut self, i: usize) -> Option<PathBuf> {
        let index = self.visible.get(i)?.clone();
        let node = self.node_mut(&index);
        if node.is_dir {
            if !node.expanded {
                node.load_children();
                node.expanded = true;
            } else {
                node.expanded = false;
            }
            self.rebuild();
            None
        } else {
            Some(node.path.clone())
        }
    }

    /// `h` on row `i`: collapse it, or jump to its parent.
    pub fn collapse(&mut self, i: usize) {
        let Some(index) = self.visible.get(i).cloned() else { return };
        let node = self.node_mut(&index);
        if node.is_dir && node.expanded && !index.is_empty() {
            node.expanded = false;
            self.rebuild();
        } else if !index.is_empty() {
            let parent = &index[..index.len() - 1];
            if let Some(pos) = self.visible.iter().position(|p| p.as_slice() == parent) {
                self.list.selected = pos;
            }
        }
    }

    /// Select and reveal `path` if it is under the root.
    pub fn reveal(&mut self, path: &Path) {
        let Ok(rel) = path.strip_prefix(&self.root.path) else { return };
        let components: Vec<String> = rel.components().map(|c| c.as_os_str().to_string_lossy().to_string()).collect();
        let mut index = Vec::new();
        let mut node = &mut self.root;
        for (depth, comp) in components.iter().enumerate() {
            node.load_children();
            let Some(i) = node.children.iter().position(|c| &c.name == comp) else { return };
            index.push(i);
            node = &mut node.children[i];
            if depth + 1 < components.len() {
                node.expanded = true;
            }
        }
        self.rebuild();
        if let Some(pos) = self.visible.iter().position(|p| *p == index) {
            self.list.selected = pos;
        }
    }
}
