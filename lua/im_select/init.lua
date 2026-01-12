local config = require("im_select.config")
local events = require("im_select.events")
local im = require("im_select.im")

local M = {}

local initialized = false

M.setup = function(opts)
    if initialized then
        return
    end

    local cfg = config.get_config()

    if opts then
        for k, v in pairs(opts) do
            cfg[k] = v
        end
    end

    cfg = config.set_platform_defaults(cfg)

    if not config.should_enable(cfg) then
        return
    end

    im.set_config(cfg)
    vim.g.im_select_default = cfg.im_select_default

    local group_id = vim.api.nvim_create_augroup("im_select", { clear = true })

    local insert_events = { "InsertEnter" }
    if cfg.im_select_enable_cmd_line == 1 then
        table.insert(insert_events, "CmdLineEnter")
    end
    vim.api.nvim_create_autocmd(insert_events, {
        callback = events.on_insert_enter,
        group = group_id,
    })

    local leave_events = { "InsertLeave" }
    if cfg.im_select_enable_cmd_line == 1 then
        table.insert(leave_events, "CmdLineLeave")
    end
    vim.api.nvim_create_autocmd(leave_events, {
        callback = events.on_insert_leave,
        group = group_id,
    })

    if vim.fn.exists("##TermEnter") == 1 then
        vim.api.nvim_create_autocmd("TermEnter", {
            callback = events.on_insert_enter,
            group = group_id,
        })
    end

    if vim.fn.exists("##TermLeave") == 1 then
        vim.api.nvim_create_autocmd("TermLeave", {
            callback = events.on_insert_leave,
            group = group_id,
        })
    end

    if cfg.im_select_enable_focus_events == 1 then
        vim.api.nvim_create_autocmd("FocusGained", {
            callback = events.on_focus_gained,
            group = group_id,
        })
        vim.api.nvim_create_autocmd("FocusLost", {
            callback = events.on_focus_lost,
            group = group_id,
        })
    end

    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = events.on_vim_leave_pre,
        group = group_id,
    })

    initialized = true
end

M.enable = function()
    M.setup()
end

M.disable = function()
    vim.api.nvim_clear_autocmds({ group = "im_select" })
    initialized = false
end

return M
