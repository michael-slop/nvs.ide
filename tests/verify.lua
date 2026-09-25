-- Headless checks for the nvs.ide runtime. Run inside a sandboxed install so
-- nothing touches your own config (PowerShell, from the repo root):
--   $sb = "$env:TEMP\nvs-sandbox"
--   foreach ($d in 'config','data','state','cache') { New-Item -ItemType Directory -Force "$sb\$d" | Out-Null }
--   $env:XDG_CONFIG_HOME="$sb\config"; $env:XDG_DATA_HOME="$sb\data"; $env:XDG_STATE_HOME="$sb\state"; $env:XDG_CACHE_HOME="$sb\cache"
--   $env:NVIM_APPNAME = 'nvs-ide'
--   Copy-Item -Recurse runtime "$sb\config\nvs-ide"; nvim --headless "+Lazy! sync" +qa
--   nvim --headless -c "luafile tests/verify.lua"
-- Every line printed starts with PASS or FAIL.
local out = {}
local function check(name, ok, detail) table.insert(out, (ok and "PASS " or "FAIL ") .. name .. (detail and ("  (" .. detail .. ")") or "")) end
vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy" })
vim.wait(500)
check("colorscheme", vim.g.colors_name == "necronomicon", vim.g.colors_name)
for _, c in ipairs({ "NvsStage", "NvsAsk", "NvsTutor", "NvsAI", "NvsModel", "NvsWelcome" }) do
  check("command :" .. c, vim.fn.exists(":" .. c) == 2)
end
local function rhs(mode, lhs) local m = vim.fn.maparg(lhs, mode, false, true); return m and m.desc or "" end
check("stage default", vim.g.nvs_stage == 2, tostring(vim.g.nvs_stage))
check("<C-p> find file at stage 2", rhs("n", "<C-P>") == "Find file", rhs("n", "<C-P>"))
check("<C-/> comment at stage 2", rhs("n", "<C-/>") == "Toggle comment", rhs("n", "<C-/>"))
check("<leader>? is Ask", rhs("n", " ?"):find("Ask") ~= nil, rhs("n", " ?"))
check("<leader>Nt tutor", rhs("n", " Nt"):find("Tutor") ~= nil)
check("LazyVim <C-s> save kept", rhs("n", "<C-S>") ~= "", rhs("n", "<C-S>"))
require("nvs.stages").set(4)
check("stage 4 removes <C-p>", rhs("n", "<C-P>") == "", rhs("n", "<C-P>"))
check("stage 4 restores LazyVim <C-/>", rhs("n", "<C-/>"):find("Terminal") ~= nil, rhs("n", "<C-/>"))
check("stage 4 restores LazyVim t_<C-/>", rhs("t", "<C-/>") ~= "", rhs("t", "<C-/>"))
require("nvs.stages").set(1)
check("stage 1 maps i_<Esc>", rhs("i", "<Esc>"):find("Stage 1") ~= nil)
require("nvs.stages").set(2)
check("stage 2 restores LazyVim i_<Esc>", not rhs("i", "<Esc>"):find("Stage 1"), rhs("i", "<Esc>"))
local saved = vim.fn.json_decode(vim.fn.readfile(vim.fn.stdpath("data") .. "/nvs-ide.json"))
check("state saved to disk", saved.stage == 2)
-- Settings saved before the llama.cpp backend existed move over to the Ollama backend.
local st = require("nvs.state")
local file = vim.fn.stdpath("data") .. "/nvs-ide.json"
local keep = vim.fn.readfile(file)
vim.fn.writefile({ vim.json.encode({ stage = 2, ollama = { enabled = true, url = "http://box:11434", chat_model = "m1" } }) }, file)
st.load()
check("old Ollama settings migrate", st.data.ai.backend == "ollama" and st.data.ai.enabled and st.data.ai.ollama.url == "http://box:11434" and st.data.ai.chat_model == "m1")
vim.fn.writefile(keep, file)
st.load()
check("built-in llama.cpp is the default backend", st.defaults.ai.backend == "llamacpp")
check("ask: local AI question", require("nvs.ask").search("use ollama", 1)[1].entry.id == "local-ai")
local r = require("nvs.ask").search("delete a line", 1)[1]
check("ask: delete a line", r and r.entry.id == "delete-line")
vim.cmd("NvsTutor")
check("tutor opens", vim.api.nvim_buf_get_name(0):find("nvs%-ide%.tutor") ~= nil, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
check("tutor expectations loaded", vim.b.tutor_metadata and vim.b.tutor_metadata.expect and vim.b.tutor_metadata.expect["54"] ~= nil)
require("nvs.ask").answer("delete a line")
check("ask window opens", vim.bo.filetype == "markdown" and vim.api.nvim_win_get_config(0).relative == "editor")
check("ask window content", table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("dd") ~= nil)
local msgs = vim.api.nvim_exec2("messages", { output = true }).output
check("no errors in :messages", not msgs:find("E%d+:") and not msgs:find("Error"), msgs:sub(1, 300))
io.write(table.concat(out, "\n") .. "\n")
vim.cmd("qa!")
