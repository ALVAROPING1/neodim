local TSHighlighter = vim.treesitter.highlighter
local Range = vim.treesitter._range

local Color = require 'neodim.Color'
local config = require 'neodim.config'
local list = require 'neodim.list'
local lsp = require 'neodim.lsp'

local NAMESPACE = vim.api.nvim_create_namespace 'treesitter/highlighter'

---@class neodim.ColumnRange
---@field start_col integer
---@field end_col integer

---@class neodim.TSOverride
---@field diagnostics_map table<integer, table<integer, neodim.ColumnRange[]>>
---@field highlight_cache table<string, string>
local TSOverride = {}
---@private
TSOverride.__index = TSOverride

---@return self
TSOverride.init = function()
  ---@type neodim.TSOverride
  local self = setmetatable({
    diagnostics_map = {},
    highlight_cache = {},
  }, TSOverride)
  local use_range = vim.fn.has 'nvim-0.12' == 1

  -- these are 'private' but technically accessible
  -- if that every changes, we will have to override the whole TSHighlighter
  vim.api.nvim_set_decoration_provider(NAMESPACE, {
    on_win = self:set_override_win(),
    on_line = not use_range and self:set_override_line() or nil,
    on_range = use_range and self:set_override_range() or nil,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    callback = function()
      for _, hl in pairs(self.highlight_cache) do
        vim.api.nvim_set_hl(0, hl, {})
      end
      self.highlight_cache = {}
    end,
  })

  return self
end

---@return function
TSOverride.set_override_win = function(self)
  ---@param winid integer
  ---@param bufnr integer
  ---@param top integer
  ---@param bottom integer
  local function on_win(_, winid, bufnr, top, bottom)
    TSHighlighter._on_win(_, winid, bufnr, top, bottom) ---@diagnostic disable-line: invisible
    local map_buf = self.diagnostics_map[bufnr]
    if not map_buf then
      return false
    end
    for i = top, bottom do
      local range_list = map_buf[i]
      if range_list and range_list[1] then
        return true
      end
    end
    return false
  end

  return on_win
end

---@return function
TSOverride.set_override_line = function(self)
  local on_range = self:set_override_range()
  ---@param win integer
  ---@param buf integer
  ---@param line integer
  local function on_line(_, win, buf, line)
    on_range('range', win, buf, line, 0, line + 1, 0)
  end

  return on_line
end

---@return function
TSOverride.set_override_range = function(self)
  ---@param win integer
  ---@param buf integer
  ---@param br integer
  ---@param bc integer
  ---@param er integer
  ---@param ec integer
  local function on_range(_, win, buf, br, bc, er, ec)
    local highlighter = TSHighlighter.active[buf]
    if not highlighter then
      return
    end

    return self:on_range_impl(highlighter, win, buf, br, bc, er, ec)
  end

  return on_range
end

---@param diagnostics vim.Diagnostic[]
---@param bufnr integer
TSOverride.update_unused = function(self, diagnostics, bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    self.diagnostics_map[bufnr] = nil
    return
  end
  local ft = vim.api.nvim_get_option_value('filetype', { buf = bufnr })
  if config.opts.disable[ft] then
    self.diagnostics_map[bufnr] = nil
    return
  end

  local map_buf = {}
  self.diagnostics_map[bufnr] = map_buf

  for _, diagnostic in ipairs(diagnostics) do
    local start_row, start_col = diagnostic.lnum, diagnostic.col
    local end_row = diagnostic.end_lnum or start_row
    local end_col = diagnostic.end_col or start_col

    for row = start_row, end_row do
      local range ---@type neodim.ColumnRange
      if start_row == end_row then
        range = { start_col = start_col, end_col = end_col }
      elseif row == start_row then
        range = { start_col = start_col, end_col = math.huge }
      elseif row == end_row then
        range = { start_col = 0, end_col = end_col }
      else
        range = { start_col = 0, end_col = math.huge }
      end

      local range_list = map_buf[row]
      if not range_list then
        range_list = list.new()
        map_buf[row] = range_list
      end
      list.insert(range_list, range)
    end
  end
end

---@param row integer
---@param col integer
---@return boolean
TSOverride.is_unused = function(self, bufnr, row, col)
  local map_buf = self.diagnostics_map[bufnr]
  if not map_buf then
    return false
  end
  local range_list = map_buf[row]
  if not range_list then
    return false
  end
  for _, range in list.iter(range_list) do
    if range.start_col <= col and col <= range.end_col then
      return true
    end
  end
  return false
end

---@param hl vim.api.keyset.highlight
---@param hl_name string
---@return string
TSOverride.get_dim_color = function(self, hl, hl_name)
  if not self.highlight_cache[hl_name] and hl and hl.fg then
    hl.fg = tostring(Color.from_int(hl.fg):blend(config.opts.blend_color, config.opts.alpha))
    local unused_name = hl_name .. 'Unused'
    vim.api.nvim_set_hl(0, unused_name, hl)
    self.highlight_cache[hl_name] = unused_name
  end

  return self.highlight_cache[hl_name]
end

---@param mark vim.api.keyset.set_extmark
---@param buf integer
---@param start_row integer
---@param start_col integer
---@return boolean
TSOverride.override_mark_with_lsp = function(self, mark, buf, start_row, start_col)
  local sttoken_mark_data = lsp.get_sttoken_mark_data(buf, start_row, start_col)
  if sttoken_mark_data then
    mark.hl_group = self:get_dim_color(sttoken_mark_data.hl_opts, sttoken_mark_data.hl_name)
    mark.priority = config.opts.priority
    return true
  end
  return false
end

---@param mark vim.api.keyset.set_extmark
---@param hl_query vim.treesitter.highlighter.Query
---@param capture integer
---@return boolean
TSOverride.override_mark_with_ts = function(self, mark, hl_query, capture)
  ---@diagnostic disable-next-line: invisible
  local hl = hl_query:get_hl_from_capture(capture)
  if not hl or hl == 0 then
    return false
  end
  local capture_name = hl_query:query().captures[capture]
  mark.hl_group = self:get_dim_color(
    vim.api.nvim_get_hl(0, { id = hl, link = false }) --[[@as vim.api.keyset.highlight]],
    '@' .. capture_name
  )
  mark.priority = config.opts.priority
  return true
end

---@param highlighter vim.treesitter.highlighter
---@param win integer
---@param buf integer
---@param range_start_row integer
---@param range_start_col integer
---@param range_end_row integer
---@param range_end_col integer
TSOverride.on_range_impl = function(
    self,
    highlighter,
    win,
    buf,
    range_start_row,
    range_start_col,
    range_end_row,
    range_end_col
)
  ---@diagnostic disable-next-line: invisible
  ---@param state vim.treesitter.highlighter.State
  local function callback(state)
    local root_node = state.tstree:root()
    ---@type { [1]: integer, [2]: integer, [3]: integer, [4]: integer }
    local root_range = { root_node:range() }

    if not Range.intercepts(root_range, { range_start_row, range_start_col, range_end_row, range_end_col }) then
      return
    end

    local query = state.highlighter_query:query()
    local iter = query:iter_captures(
      root_node,
      buf,
      range_start_row,
      range_end_row,
      { start_col = range_start_col, end_col = range_end_col }
    )
    for capture, node, metadata in iter do
      local range = vim.treesitter.get_range(node, buf, metadata[capture])
      local start_row, start_col, end_row, end_col = Range.unpack4(range)
      ---@type vim.api.keyset.set_extmark
      local mark = {
        end_row = end_row,
        end_col = end_col,
        ephemeral = true,
      }
      if
          self:is_unused(buf, start_row, start_col)
          and (
            self:override_mark_with_lsp(mark, buf, start_row, start_col)
            or self:override_mark_with_ts(mark, state.highlighter_query, capture)
          )
      then
        vim.api.nvim_buf_set_extmark(buf, NAMESPACE, start_row, start_col, mark)
      end
    end
  end
  if vim.fn.has 'nvim-0.11.3' == 1 and vim.fn.has 'nvim-0.12' == 0 then
    ---@diagnostic disable-next-line: invisible
    highlighter:for_each_highlight_state(win, callback)
  else
    ---@diagnostic disable-next-line: invisible
    highlighter:for_each_highlight_state(callback)
  end
end

return TSOverride
