local im = require("im_select.im")
local state = require("im_select.state")
local config = require("im_select.config")

local M = {}

---@class im_select.StrategyContext
---@field char_before string|nil
---@field charcode_before number|nil
---@field char_after string|nil
---@field charcode_after number|nil
---@field filetype string
---@field line_content string
---@field is_inside_comment boolean
---@field config im_select.Config
---@alias im_select.Strategy fun(ctx: im_select.StrategyContext): string|nil

local function is_insert_or_cmdline_mode()
	local mode = vim.fn.mode()
	return mode:match("^[ciRsSt]$")
end

local function has_comment_ancestor(node)
	local max_depth = 10
	while node and max_depth > 0 do
		if node:type():match("comment") then
			return true
		end
		node = node:parent()
		max_depth = max_depth - 1
	end
	return false
end

local function is_inner_comment(row, col)
	local bufnr = 0

	local function get_node_at(r, c)
		return vim.treesitter.get_node({
			bufnr = bufnr,
			pos = { r, c },
			include_anonymous = true,
		})
	end

	-- 1️⃣ 先检测当前位置
	local node = get_node_at(row, col)
	if node and has_comment_ancestor(node) then
		return true
	end

	-- 2️⃣ 如果在行尾，回退一列再检测（关键修复）
	if col > 0 then
		local prev_node = get_node_at(row, col - 1)
		if prev_node and has_comment_ancestor(prev_node) then
			return true
		end
	end

	return false
end

local function get_context_before_cursor()
	local row = vim.fn.line(".") - 1
	local col = vim.fn.col(".") - 1

	local char_before = nil
	local charcode_before = nil
	local char_after = nil
	local charcode_after = nil

	if col > 0 then
		local start_col = math.max(0, col - 4)
		local ok, text_lines = pcall(vim.api.nvim_buf_get_text, 0, row, start_col, row, col, {})
		if ok and #text_lines > 0 then
			char_before = vim.fn.matchstr(text_lines[1], ".$")
			charcode_before = vim.fn.char2nr(char_before)
		end
	end

	local line_len = vim.fn.col("$") - 1
	if col < line_len then
		local end_col = math.min(line_len, col + 4)
		local ok, text_lines = pcall(vim.api.nvim_buf_get_text, 0, row, col, row, end_col, {})
		if ok and #text_lines > 0 then
			char_after = vim.fn.matchstr(text_lines[1], "^.")
			charcode_after = vim.fn.char2nr(char_after)
		end
	end

	local line_content = vim.fn.getline(".")
	if #line_content > 1000 then
		line_content = line_content:sub(1, 1000)
	end

	local is_comment = is_inner_comment(row, col)

	return {
		char_before = char_before,
		charcode_before = charcode_before,
		char_after = char_after,
		charcode_after = charcode_after,
		filetype = vim.bo.filetype,
		line_content = line_content,
		is_inside_comment = is_comment,
	}
end

local function execute_strategies(strategies, cfg)
	local context = get_context_before_cursor()
	context.config = cfg
	for _, strategy in ipairs(strategies) do
		if type(strategy) == "function" then
			local result = strategy(context)
			if result ~= nil then
				return result
			end
		end
	end
	return nil
end

M.strategy_default = function(context)
	---@cast context im_select.StrategyContext
	if state.get_prev_im() and state.get_prev_im() ~= "" then
		return state.get_prev_im()
	elseif context.config.ImSelectGetImCallback then
		im.get_and_set_prev_im(context.config.ImSelectGetImCallback)
		return state.get_prev_im()
	else
		return context.config.im_select_default
	end
end

-- 等同于 InsertEnter
M.on_insert_enter = function()
	if state.get_focus_event_enabled() == 0 then
		return
	end

	local cfg = im.get_config() or config.get_config()

	local mode = vim.fn.mode()
	if mode:match("^c") then
		im.set_im(cfg.im_select_default)
		return
	end

	local strategies = cfg.insert_enter_strategies or { M.strategy_default }

	local result_im = execute_strategies(strategies, cfg)

	if result_im then
		im.set_im(result_im)
	end
end

M.on_insert_leave_get_im_callback = function(code, stdout, stderr)
	local cfg = im.get_config() or config.get_config()
	local cur_im = cfg.ImSelectGetImCallback and cfg.ImSelectGetImCallback(code, stdout, stderr) or stdout
	im.set_im(cfg.im_select_default)
	return cur_im
end

M.on_insert_leave = function()
	if state.get_focus_event_enabled() == 0 then
		return
	end

	im.get_and_set_prev_im(M.on_insert_leave_get_im_callback)
end

M.on_focus_gained_get_im_callback = function(code, stdout, stderr)
	local cfg = im.get_config() or config.get_config()
	local cur_im = cfg.ImSelectGetImCallback and cfg.ImSelectGetImCallback(code, stdout, stderr) or stdout
	im.set_im(cfg.im_select_default)
	return cur_im
end

M.on_focus_gained = function()
	if state.get_focus_event_enabled() == 0 then
		return
	end

	if not is_insert_or_cmdline_mode() then
		im.get_and_set_prev_im(M.on_focus_gained_get_im_callback)
	end
end

M.on_focus_lost = function()
	if state.get_focus_event_enabled() == 0 then
		return
	end

	if not is_insert_or_cmdline_mode() then
		if state.get_prev_im() and state.get_prev_im() ~= "" then
			im.set_im(state.get_prev_im())
		else
			local cfg = im.get_config() or config.get_config()
			if cfg.ImSelectGetImCallback then
				im.get_and_set_prev_im(cfg.ImSelectGetImCallback)
			end
		end
	end
end

M.on_vim_leave_pre = function()
	if not state.is_gui() then
		return
	end

	local cfg = im.get_config() or config.get_config()

	if is_insert_or_cmdline_mode() then
		return
	end

	if state.get_prev_im() and state.get_prev_im() ~= "" then
		local prev_im = state.get_prev_im()
		if prev_im then
			local set_cmd = cfg.ImSelectSetImCmd(prev_im)
			local cmd = table.concat(set_cmd, " ")
			vim.fn.system("silent !" .. cmd)
		end
	end
end

return M
