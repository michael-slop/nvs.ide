-- Live local-AI checks: needs llama-server and at least one Qwen GGUF in the models
-- folder, and downloads a ~340 MB model from Hugging Face. Set up a sandbox as in
-- tests/verify.lua, then before running:
--   :NvsAI on
--   :NvsAI server <path to llama-server>
--   (put a qwen2.5-coder GGUF in the folder :NvsModel folder opens)
--   nvim --headless -c "luafile tests/ai_live.lua"
local out = {}
local function check(name, ok, detail) table.insert(out, (ok and "PASS " or "FAIL ") .. name .. (detail and ("  (" .. tostring(detail):gsub("\n", " / "):sub(1, 220) .. ")") or "")) end
vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy" })
local ai = require("nvs.ai")
check("backend is llamacpp", require("nvs.state").data.ai.backend == "llamacpp")
check("server found", ai.server_path() ~= nil, ai.server_path())
local list
ai.models(function(err, l) list = l or { err = err } end)
vim.wait(60000, function() return list ~= nil end, 200)
check("router lists models", list and list[1] and list[1].id:find("qwen") ~= nil, list and (list.err or vim.inspect(vim.tbl_map(function(m) return m.id end, list))))
local res
ai.resolve("Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M", function(e, p) res = p or e end)
vim.wait(20000, function() return res ~= nil end, 100)
check("resolve repo:quant", type(res) == "table" and res[1].file == "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf", type(res) == "table" and res[1].url or res)
local res7
ai.resolve("Qwen/Qwen2.5-Coder-7B-Instruct-GGUF:q4_k_m", function(e, p) res7 = p or e end)
vim.wait(20000, function() return res7 ~= nil end, 100)
check("resolve prefers single file", type(res7) == "table" and #res7 == 1 and res7[1].file == "qwen2.5-coder-7b-instruct-q4_k_m.gguf", type(res7) == "table" and #res7 or res7)
-- Ask with no written answer -> the model
local notes = {}
local orig = vim.notify
vim.notify = function(m, l, o) table.insert(notes, tostring(m)); return orig(m, l, o) end
local t0 = vim.uv.now()
require("nvs.ask").answer("what is the capital of france")
vim.wait(240000, function() return vim.bo.filetype == "markdown" and vim.api.nvim_win_get_config(0).relative == "editor" end, 250)
local body = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
check("ask falls back to the model", body:find("Answer from qwen") ~= nil, ("%.1fs: %s"):format((vim.uv.now() - t0) / 1000, body:sub(1, 200)))
check("model answer mentions Paris", body:lower():find("paris") ~= nil)
vim.cmd("close")
-- download a small model through :NvsModel pull
local pulled
ai.pull("Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF:q2_k", function(e, f) pulled = f or ("ERR " .. tostring(e)) end)
vim.wait(300000, function() return pulled ~= nil end, 250)
check("pull downloads a model", pulled == "qwen2.5-coder-0.5b-instruct-q2_k.gguf", pulled)
local list2
ai.models(function(err, l) list2 = l or { err = err } end)
vim.wait(60000, function() return list2 ~= nil end, 200)
local ids = vim.tbl_map(function(m) return m.id end, list2)
check("restarted server lists the new model", vim.tbl_contains(ids, "qwen2.5-coder-0.5b-instruct-q2_k"), vim.inspect(ids))
check("fim template for qwen", ai.fim_template("qwen2.5-coder-1.5b"):find("<|fim_prefix|>", 1, true) ~= nil)
-- minuet picks up the llama.cpp config
vim.api.nvim_exec_autocmds("InsertEnter", {})
vim.wait(2000)
local okm, minuet = pcall(require, "minuet")
local fimcfg = okm and minuet.config and minuet.config.provider_options.openai_fim_compatible
check("minuet uses llama-server", fimcfg and fimcfg.end_point == "http://127.0.0.1:8012/v1/completions", fimcfg and fimcfg.end_point)
check("minuet FIM prompt", fimcfg and fimcfg.template and fimcfg.template.prompt("a", "b") == "<|fim_prefix|>a<|fim_suffix|>b<|fim_middle|>", fimcfg and fimcfg.template and fimcfg.template.prompt("a", "b"))
io.write(table.concat(out, "\n") .. "\n")
vim.cmd("qa!")
