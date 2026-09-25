//! Pixel icons, drawn rather than emoji. The bitmaps are the mockup's (docs/preview/src.html,
//! `PX`), rasterised into the glyph atlas as tiles so an icon is one quad.

pub struct Icon {
    pub name: &'static str,
    pub rows: &'static [&'static str],
}

pub const ICONS: &[Icon] = &[
    Icon { name: "explorer", rows: &["..#####...", "..#...##..", "..#....#..", "#####..#..", "#...##.#..", "#....#.#..", "#....#.#..", "#....###..", "#....#....", "######...."] },
    Icon { name: "search", rows: &[".####.....", "#....#....", "#....#....", "#....#....", "#....#....", ".####.....", ".....##...", "......##..", ".......##.", "........##"] },
    Icon { name: "git", rows: &[".##....##.", ".##....##.", "..#....#..", "..#...#...", "..#..#....", "..#.#.....", "..##......", "..#.......", ".##.......", ".##......."] },
    Icon { name: "debug", rows: &["#.........", "##........", "###.......", "####......", "#####.....", "######....", "#####.....", "####......", "###.......", "##........"] },
    Icon { name: "plugins", rows: &["####......", "#..#.####.", "####.#..#.", ".....####.", "####......", "#..#.####.", "####.#..#.", ".....####.", "..........", ".........."] },
    Icon { name: "ask", rows: &["..####....", ".#....#...", "......#...", ".....#....", "....#.....", "....#.....", "..........", "....#.....", "..........", ".........."] },
    Icon { name: "learn", rows: &["..........", "####..####", "#..#..#..#", "#..####..#", "#........#", "#........#", "#........#", "##########", "....##....", ".........."] },
    Icon { name: "settings", rows: &[".#...#..#.", "###..#..#.", ".#...#..#.", ".#..###.#.", ".#...#..#.", ".#...#.###", ".#...#..#.", ".#...#..#.", ".#...#..#.", ".........."] },
    Icon { name: "file", rows: &["#####...", "#...##..", "#....#..", "#....#..", "#....#..", "#....#..", "######.."] },
    Icon { name: "folder", rows: &["###.....", "#######.", "#.....#.", "#.....#.", "#.....#.", "#######."] },
    Icon { name: "x", rows: &["#...#", ".#.#.", "..#..", ".#.#.", "#...#"] },
    Icon { name: "min", rows: &[".....", ".....", ".....", ".....", "#####"] },
    Icon { name: "max", rows: &["#####", "#####", "#...#", "#...#", "#####"] },
    Icon { name: "logo", rows: &["#...#", "##..#", "#.#.#", "#..##", "#...#"] },
    Icon { name: "play", rows: &["#...", "##..", "###.", "##..", "#..."] },
    Icon { name: "stop", rows: &["####", "####", "####", "####"] },
    Icon { name: "step", rows: &["#..#", "##.#", "####", "##.#", "#..#"] },
    Icon { name: "pkg", rows: &["..####..", ".#....#.", "########", "#......#", "#..##..#", "#......#", "########"] },
    Icon { name: "gear", rows: &[".#.##.#.", "########", ".##..##.", "##....##", "##....##", ".##..##.", "########", ".#.##.#."] },
    Icon { name: "dot", rows: &[".##.", "####", "####", ".##."] },
    Icon { name: "check", rows: &[".......#", "......##", ".....##.", "#...##..", "##.##...", ".###....", "..#....."] },
    Icon { name: "cross", rows: &["##....##", ".##..##.", "..####..", "...##...", "..####..", ".##..##.", "##....##"] },
    Icon { name: "chevron-right", rows: &["#....", "##...", ".##..", "..##.", ".##..", "##...", "#...."] },
    Icon { name: "chevron-down", rows: &["#.....#", "##...##", ".##.##.", "..###..", "...#..."] },
];

pub fn index_of(name: &str) -> Option<u16> {
    ICONS.iter().position(|i| i.name == name).map(|i| i as u16)
}

/// Rasterise icon `index` at `scale` px per source pixel into an alpha mask.
pub fn rasterize(index: u16, scale: u32) -> Option<(u32, u32, Vec<u8>)> {
    let icon = ICONS.get(index as usize)?;
    let rows = icon.rows.len() as u32;
    let cols = icon.rows.iter().map(|r| r.len()).max().unwrap_or(0) as u32;
    let (w, h) = (cols * scale, rows * scale);
    let mut data = vec![0u8; (w * h) as usize];
    for (ry, row) in icon.rows.iter().enumerate() {
        for (rx, c) in row.bytes().enumerate() {
            if c == b'#' {
                for dy in 0..scale {
                    for dx in 0..scale {
                        let x = rx as u32 * scale + dx;
                        let y = ry as u32 * scale + dy;
                        data[(y * w + x) as usize] = 255;
                    }
                }
            }
        }
    }
    Some((w, h, data))
}
