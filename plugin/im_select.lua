if vim.g.im_select_loaded then
    return
end
vim.g.im_select_loaded = 1

local im_select = require("im_select.init")

im_select.setup()

vim.api.nvim_create_user_command("ImSelectEnable", function()
    im_select.enable()
end, {})

vim.api.nvim_create_user_command("ImSelectDisable", function()
    im_select.disable()
end, {})
