local M = {}

local focus_event_enabled = 1
local gui = false
local prev_im = nil

local function detect_gui()
    if vim.fn.exists("g:GuiLoaded") == 1 and vim.g.GuiLoaded ~= 0 then
        gui = true
    elseif
        pcall(function()
            local uis = vim.api.nvim_list_uis()
            if #uis > 0 then
                local ext_termcolors = uis[1].ext_termcolors
                gui = ext_termcolors == nil or ext_termcolors == 0
            end
        end)
    then
    elseif vim.fn.exists("+termguicolors") == 1 and vim.o.termguicolors then
        gui = true
    end
end

detect_gui()

M.get_focus_event_enabled = function()
    return focus_event_enabled
end

M.set_focus_event_enabled = function(value)
    focus_event_enabled = value
end

M.focus_event_timer_handler = function()
    focus_event_enabled = 1
end

M.is_gui = function()
    return gui
end

M.get_prev_im = function()
    return prev_im
end

M.set_prev_im = function(value)
    prev_im = value
end

return M
