local im = require("im_select.im")
local state = require("im_select.state")
local config = require("im_select.config")

local M = {}

local function is_insert_or_cmdline_mode()
    local mode = vim.fn.mode()
    return mode:match("^[ciRsSt]$")
end

M.on_insert_enter = function()
    if state.get_focus_event_enabled() == 0 then
        return
    end

    local cfg = im.get_config() or config.get_config()

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
