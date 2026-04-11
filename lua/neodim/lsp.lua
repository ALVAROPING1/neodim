local api = vim.api
local util = vim.lsp.util
local STHighlighter = vim.lsp.semantic_tokens.__STHighlighter

local list = require 'neodim.list'
local vim_list = vim.list or {}

local M = {}

-- NOTE: backported from nvim 0.12
-- TODO: remove when dropping support for nvim 0.11
if vim.fn.has 'nvim-0.12' == 0 then
  ---@generic T
  ---@param v T
  ---@param key? fun(v: T): any
  ---@return any
  local function key_fn(v, key)
    return key and key(v) or v
  end

  ---@generic T
  ---@param t T[]
  ---@param val T
  ---@param key? fun(val: any): any
  ---@param lo integer
  ---@param hi integer
  ---@return integer i
  local function lower_bound(t, val, lo, hi, key)
    local bit = require 'bit' -- Load bitop on demand
    local val_key = key_fn(val, key)
    while lo < hi do
      local mid = bit.rshift(lo + hi, 1) -- Equivalent to floor((lo + hi) / 2)
      if key_fn(t[mid], key) < val_key then
        lo = mid + 1
      else
        hi = mid
      end
    end
    return lo
  end

  ---@generic T
  ---@param t T[]
  ---@param val T
  ---@param key? fun(val: any): any
  ---@param lo integer
  ---@param hi integer
  ---@return integer i
  local function upper_bound(t, val, lo, hi, key)
    local bit = require 'bit' -- Load bitop on demand
    local val_key = key_fn(val, key)
    while lo < hi do
      local mid = bit.rshift(lo + hi, 1) -- Equivalent to floor((lo + hi) / 2)
      if val_key < key_fn(t[mid], key) then
        hi = mid
      else
        lo = mid + 1
      end
    end
    return lo
  end

  ---@generic T
  ---@param t T[] A comparable list.
  ---@param val T The value to search.
  ---@param opts? vim.list.bisect.Opts
  ---@return integer index serves as either the lower bound or the upper bound position.
  function vim_list.bisect(t, val, opts)
    vim.validate('t', t, 'table')
    vim.validate('opts', opts, 'table', true)

    opts = opts or {}
    local lo = opts.lo or 1
    local hi = opts.hi or #t + 1
    local key = opts.key

    if opts.bound == 'upper' then
      return upper_bound(t, val, lo, hi, key)
    else
      return lower_bound(t, val, lo, hi, key)
    end
  end
end

--- @param lnum integer
--- @param foldend integer?
--- @return boolean, integer?
local function check_fold(lnum, foldend)
  if foldend and lnum <= foldend then
    return true, foldend
  end

  local folded = vim.fn.foldclosed(lnum)

  if folded == -1 then
    return false, nil
  end

  return folded ~= lnum, vim.fn.foldclosedend(lnum)
end

---@param buf integer
---@param topline integer
---@param botline integer
---@param fn fun(ns: integer, token: STTokenRange): integer|boolean|nil
function M.for_each_token(buf, topline, botline, fn)
  local self = STHighlighter.active[buf]
  if not self then
    return
  end
  for _, state in pairs(self.client_state) do
    local current_result = state.current_result
    if current_result.version == util.buf_versions[self.bufnr] then
      local highlights = assert(current_result.highlights)
      -- NOTE: `end_line` was added in nvim 0.12
      -- TODO: remove `line` when dropping support for nvim 0.11
      local first = vim_list.bisect(highlights, { line = topline, end_line = topline }, {
        key = function(highlight)
          return highlight.end_line or highlight.line
        end,
      })
      local last = vim_list.bisect(highlights, { line = botline }, {
        lo = first,
        bound = 'upper',
        key = function(highlight)
          return highlight.line
        end,
      }) - 1

      --- @type boolean?, integer?
      local is_folded, foldend

      local i = first
      while i <= last do
        local token = assert(highlights[i])
        is_folded, foldend = check_fold(token.line + 1, foldend)
        if not is_folded then
          local next_line = fn(state.namespace, token)
          if next_line == false then
            return
          elseif next_line then
            i = vim_list.bisect(highlights, { end_line = next_line }, {
              lo = i + 1,
              hi = last + 1,
              key = function(highlight)
                return highlight.end_line
              end,
            }) - 1
          end
        end
        i = i + 1
      end
    end
  end
end

---@alias extmark_data { priority: integer, hl_name: string, hl_opts: table }?

---@class extmark
---@field [1] integer mark ID
---@field [2] integer row
---@field [3] integer column
---@field [4] extmark_details

---@class extmark_details
---@field hl_group string
---@field priority integer
---@field end_col integer
---@field end_row integer

---@param buf integer
---@param ns integer
---@param token_range STTokenRange
---@return extmark[]
local function get_sttoken_extmarks(buf, ns, token_range)
  local start = { token_range.line, token_range.start_col }
  local end_ = { token_range.line, token_range.end_col }
  local opts = { type = 'highlight', details = true }
  return list.from_raw(api.nvim_buf_get_extmarks(buf, ns, start, end_, opts))
end

---@param extmarks extmark[]
---@return extmark_data
local function get_max_pri_extmark(extmarks)
  local priority = 0
  local hl_name
  local hl_opts

  for _, extmark in ipairs(extmarks) do
    local details = extmark[4]
    if priority < details.priority then
      local _hl_opts = api.nvim_get_hl(0, { name = details.hl_group, link = false })
      if next(_hl_opts) then
        hl_opts = _hl_opts
        priority = details.priority
        hl_name = details.hl_group
      end
    end
  end

  if hl_name then
    return {
      priority = priority,
      hl_name = hl_name,
      hl_opts = hl_opts,
    }
  end
end

---@param buf integer
---@param ns integer
---@param token STTokenRange
---@return extmark_data?
function M.get_sttoken_mark_data(buf, ns, token)
  local extmarks = get_sttoken_extmarks(buf, ns, token)
  return get_max_pri_extmark(extmarks)
end

return M
