local config = require("im_select.config")
local job = require("im_select.job")
local state = require("im_select.state")

local M = {}

local current_config = nil

M.set_config = function(cfg)
    current_config = cfg
end

M.get_config = function()
    return current_config
end

M.get_and_set_prev_im = function(callback)
    local cfg = current_config or config.get_config()
    return job.ImGetJob.new(cfg.im_select_get_im_cmd, callback, true)
end

M.get_im = function(callback)
    local cfg = current_config or config.get_config()
    return job.ImGetJob.new(cfg.im_select_get_im_cmd, callback, false)
end

M.set_im_get_im_callback = function(im, code, stdout, stderr)
    local cfg = current_config or config.get_config()
    local cur_im = cfg.ImSelectGetImCallback and cfg.ImSelectGetImCallback(code, stdout, stderr) or stdout

    if cur_im ~= im then
        state.set_focus_event_enabled(0)
        vim.defer_fn(state.focus_event_timer_handler, cfg.im_select_switch_timeout)

        local set_cmd = cfg.ImSelectSetImCmd(im)
        job.ImSetJob.new(set_cmd)
    end

    return cur_im
end

M.set_im = function(im)
    M.get_im(function(code, stdout, stderr)
        M.set_im_get_im_callback(im, code, stdout, stderr)
    end)
end

return M
