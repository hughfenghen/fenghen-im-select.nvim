local im = require("im_select.im")
local state = require("im_select.state")
local config = require("im_select.config")

local M = {}

local function is_insert_or_cmdline_mode()
	local mode = vim.fn.mode()
	return mode:match("^[ciRsSt]$")
end

local function is_chinese_before_cursor()
	-- 1. 获取光标位置 (1-based)
	local col = vim.fn.col(".")
	-- 如果在行首，左边肯定没字符
	if col == 1 then
		return false
	end

	-- 2. 计算截取范围
	-- 我们只需要查看光标左侧的最多 4 个字节 (UTF-8 最大宽度)
	-- API 使用 0-based 索引
	local row = vim.fn.line(".") - 1
	local current_byte_idx = col - 1
	-- 起始位置：当前位置减4，但不小于0
	local start_col = math.max(0, current_byte_idx - 4)

	-- 3. 获取这一小段文本
	-- nvim_buf_get_text(buffer, start_row, start_col, end_row, end_col, opts)
	-- 结果是一个 table (lines)，我们取第一行
	local ok, text_lines = pcall(vim.api.nvim_buf_get_text, 0, row, start_col, row, current_byte_idx, {})

	-- 容错处理：如果获取失败或为空
	if not ok or #text_lines == 0 then
		return false
	end
	local text_fragment = text_lines[1]

	-- 4. 从这个片段中提取最后一个字符
	-- 即使片段开头截断了其他字符（比如乱码），'.$' 也能正确匹配到末尾那个完整的字符
	local char = vim.fn.matchstr(text_fragment, ".$")
	if char == "" then
		return false
	end

	-- 5. 判断 Unicode 范围
	local nr = vim.fn.char2nr(char)

	-- 基本汉字 (0x4E00 - 0x9FFF)
	if nr >= 0x4E00 and nr <= 0x9FFF then
		return true
	end
	-- 中文标点 (0x3000 - 0x303F)
	if nr >= 0x3000 and nr <= 0x303F then
		return true
	end
	-- 全角字符 (0xFF00 - 0xFFEF)
	if nr >= 0xFF00 and nr <= 0xFFEF then
		return true
	end

	return false
end

-- 等同于 InsertEnter
M.on_insert_enter = function()
	if state.get_focus_event_enabled() == 0 then
		return
	end

	local cfg = im.get_config() or config.get_config()

	if is_chinese_before_cursor() then
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
