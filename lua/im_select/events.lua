local im = require("im_select.im")
local state = require("im_select.state")
local config = require("im_select.config")

local M = {}

local function is_insert_or_cmdline_mode()
	local mode = vim.fn.mode()
	return mode:match("^[ciRsSt]$")
end

-- 值定义：
-- 0：其他字符
-- 1：空格（半角空格 0x0020 或全角空格 0x3000）
-- 2：中文（基本汉字、中文标点、全角字符）
local function get_char_type_before_cursor()
	local col = vim.fn.col(".")
	if col == 1 then
		return 0
	end

	local row = vim.fn.line(".") - 1
	local current_byte_idx = col - 1
	local start_col = math.max(0, current_byte_idx - 4)

	local ok, text_lines = pcall(vim.api.nvim_buf_get_text, 0, row, start_col, row, current_byte_idx, {})

	if not ok or #text_lines == 0 then
		return 0
	end
	local text_fragment = text_lines[1]

	local char = vim.fn.matchstr(text_fragment, ".$")
	if char == "" then
		return 0
	end

	local nr = vim.fn.char2nr(char)

	if nr == 0x0020 or nr == 0x3000 then
		return 1
	end

	if nr >= 0x4E00 and nr <= 0x9FFF then
		return 2
	end
	if nr >= 0x3000 and nr <= 0x303F then
		return 2
	end
	if nr >= 0xFF00 and nr <= 0xFFEF then
		return 2
	end

	return 0
end

-- 等同于 InsertEnter
M.on_insert_enter = function()
	if state.get_focus_event_enabled() == 0 then
		return
	end

	local cfg = im.get_config() or config.get_config()
	local char_type = get_char_type_before_cursor()

	if char_type == 1 then
		if vim.g.im_select_prev_im and vim.g.im_select_prev_im ~= "" then
			im.set_im(vim.g.im_select_prev_im)
		elseif cfg.ImSelectGetImCallback then
			im.get_and_set_prev_im(cfg.ImSelectGetImCallback)
		end
		return
	end

	if char_type == 2 then
		im.set_im(vim.g.im_select_native_im)
		return
	else
		im.set_im(vim.g.im_select_default)
		return
	end

	if vim.g.im_select_prev_im and vim.g.im_select_prev_im ~= "" then
		im.set_im(vim.g.im_select_prev_im)
	elseif cfg.ImSelectGetImCallback then
		im.get_and_set_prev_im(cfg.ImSelectGetImCallback)
	else
		im.set_im(vim.g.im_select_default)
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
		if vim.g.im_select_prev_im and vim.g.im_select_prev_im ~= "" then
			im.set_im(vim.g.im_select_prev_im)
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

	if vim.g.im_select_prev_im and vim.g.im_select_prev_im ~= "" then
		local set_cmd = cfg.ImSelectSetImCmd(vim.g.im_select_prev_im)
		local cmd = table.concat(set_cmd, " ")
		vim.fn.system("silent !" .. cmd)
	end
end

return M
