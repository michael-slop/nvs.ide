-- make_vsix.lua: builds the synthetic fixture.vsix in every tests/fixtures/vsx/<id>/ folder.
--
-- Run from the repo root (any machine with bsdtar: Windows 10+, macOS, Linux with libarchive):
--   nvim -u NONE -l tests/fixtures/vsx/make_vsix.lua [folder ...]
-- With folder names (acme.generic-ls ...) only those archives are built, so adding one
-- fixture does not rewrite the others' committed archives.
--
-- Each fixture folder holds the real package.json from Open VSX and files.txt, the real
-- archive's file list. The archive built here has the same layout as a real .vsix (a zip
-- with extension/, [Content_Types].xml and extension.vsixmanifest) but only the files the
-- tests need: package.json as is, every file that exists in the fixture folder (theme
-- JSONs, snippets), and stub-server.js in place of each .js/.cjs/.mjs the real archive
-- ships. node_modules and binaries are left out. The .vsix files are committed so the
-- tests need neither this script nor the network; re-run it after changing a fixture.
local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local uv = vim.uv or vim.loop

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local t = f:read("*a")
  f:close()
  return t
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local tar = "tar"
if vim.fn.has("win32") == 1 then
  tar = (vim.env.SystemRoot or "C:\\Windows") .. "\\System32\\tar.exe"
end
assert(vim.fn.executable(tar) == 1, "bsdtar was not found: " .. tar)

local stub = assert(read(here .. "/stub-server.js"), "stub-server.js is missing")

-- nvim -l puts the script's arguments in _G.arg (arg[0] is the script itself).
local only = {}
for _, a in ipairs(_G.arg or {}) do
  only[a] = true
end

local built = 0
for name, kind in vim.fs.dir(here) do
  local dir = here .. "/" .. name
  local wanted = next(only) == nil or only[name] == true
  if wanted and kind == "directory" and uv.fs_stat(dir .. "/package.json") and uv.fs_stat(dir .. "/files.txt") then
    local pkg = vim.json.decode(read(dir .. "/package.json"))
    local stage = vim.fn.tempname()
    vim.fn.mkdir(stage .. "/extension", "p")
    local n = 0
    for _, rel in ipairs(vim.fn.readfile(dir .. "/files.txt")) do
      rel = vim.trim(rel)
      local keep = rel ~= "" and not rel:find("node_modules", 1, true)
      if keep then
        local out = stage .. "/extension/" .. rel
        local src = read(dir .. "/" .. rel)
        if src then
          write(out, src)
          n = n + 1
        elseif rel:match("%.m?js$") or rel:match("%.cjs$") then
          write(out, stub)
          n = n + 1
        end
      end
    end
    write(stage .. "/[Content_Types].xml", '<?xml version="1.0" encoding="utf-8"?>\n<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="json" ContentType="application/json"/><Default Extension="js" ContentType="application/javascript"/><Default Extension="vsixmanifest" ContentType="text/xml"/></Types>\n')
    write(stage .. "/extension.vsixmanifest", ('<?xml version="1.0" encoding="utf-8"?>\n<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011"><Metadata><Identity Language="en-US" Id="%s" Version="%s" Publisher="%s"/><DisplayName>%s</DisplayName></Metadata></PackageManifest>\n'):format(pkg.name, pkg.version, pkg.publisher, pkg.displayName or pkg.name))
    local out = dir .. "/fixture.vsix"
    vim.fn.delete(out)
    local r = vim.system({ tar, "--format", "zip", "-cf", out, "-C", stage, "extension", "[Content_Types].xml", "extension.vsixmanifest" }, { text = true }):wait()
    assert(r.code == 0, "tar failed for " .. name .. ": " .. tostring(r.stderr))
    vim.fn.delete(stage, "rf")
    io.write(("built %s (%d files, %d bytes)\n"):format(out, n, uv.fs_stat(out).size))
    built = built + 1
  end
end
io.write(("%d fixture archives built\n"):format(built))
