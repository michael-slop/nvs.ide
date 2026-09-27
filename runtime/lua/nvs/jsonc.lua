-- JSON with comments and trailing commas, the dialect VS Code uses for settings,
-- themes and package.json. One decoder for prefs.lua, vsx.lua and vsx_theme.lua.
local M = {}

-- Strip // and /* */ comments outside strings, then trailing commas before ] or }.
function M.strip(text)
  local out = {}
  local i, n = 1, #text
  local in_str = false
  while i <= n do
    local ch = text:sub(i, i)
    if in_str then
      out[#out + 1] = ch
      if ch == "\\" then
        out[#out + 1] = text:sub(i + 1, i + 1)
        i = i + 1
      elseif ch == '"' then
        in_str = false
      end
      i = i + 1
    elseif ch == '"' then
      in_str = true
      out[#out + 1] = ch
      i = i + 1
    elseif ch == "/" and text:sub(i + 1, i + 1) == "/" then
      local nl = text:find("\n", i, true)
      i = nl or (n + 1)
    elseif ch == "/" and text:sub(i + 1, i + 1) == "*" then
      local close = text:find("*/", i + 2, true)
      i = close and (close + 2) or (n + 1)
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  local s = table.concat(out)
  -- Trailing commas: ",  ]" and ",  }" with any whitespace between.
  s = s:gsub(",(%s*[%]}])", "%1")
  return s
end

-- decode(text) -> ok, value_or_error
function M.decode(text)
  if type(text) ~= "string" then
    return false, "not text"
  end
  -- A UTF-8 byte order mark is common in files saved by Windows editors.
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
  local ok, value = pcall(vim.json.decode, text)
  if ok then
    return true, value
  end
  local ok2, value2 = pcall(vim.json.decode, M.strip(text))
  if ok2 then
    return true, value2
  end
  return false, tostring(value2)
end

-- read(path) -> ok, value_or_error
function M.read(path)
  local f = io.open(path, "r")
  if not f then
    return false, "cannot open " .. tostring(path)
  end
  local text = f:read("*a")
  f:close()
  return M.decode(text)
end

return M
