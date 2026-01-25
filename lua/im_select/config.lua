local M = {}

-- 平台检测
local function determine_os()
	if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		return "Windows"
	elseif vim.fn.has("win32unix") == 1 or vim.fn.has("wsl") == 1 or vim.env.PATH:match("/mnt/c/WINDOWS") then
		return "WSL"
	elseif
			vim.fn.has("mac") == 1
			or vim.fn.has("macunix") == 1
			or vim.fn.has("osx") == 1
			or vim.fn.has("osxdarwin") == 1
	then
		return "macOS"
	elseif vim.fn.has("unix") == 1 then
		return "Linux"
	else
		return "Unknown"
	end
end

-- 检测是否为 GUI 环境
local function is_gui()
	if vim.fn.exists("g:GuiLoaded") == 1 and vim.g.GuiLoaded ~= 0 then
		return true
	elseif
			pcall(function()
				local uis = vim.api.nvim_list_uis()
				if #uis > 0 then
					local ext_termcolors = uis[1].ext_termcolors
					return ext_termcolors == nil or ext_termcolors == 0
				end
			end)
	then
	elseif vim.fn.exists("+termguicolors") == 1 and vim.o.termguicolors then
		return true
	end
	return false
end

-- 默认配置
local default_config = {
	im_select_command = nil,
	im_select_default = nil,
	im_select_native_im = nil,
	im_select_get_im_cmd = nil,
	ImSelectSetImCmd = nil,
	ImSelectGetImCallback = nil,
	im_select_switch_timeout = 50,
	im_select_enable_focus_events = 1,
	im_select_enable_cmd_line = 1,
	im_select_enable_for_gvim = 0,
}

-- 获取用户配置
M.get_config = function(opts)
	local config = vim.deepcopy(default_config)

	-- 从 opts 获取用户配置（优先）
	if opts then
		for k, v in pairs(opts) do
			config[k] = v
		end
	end

	-- 从 vim.g 获取用户配置（向后兼容）
	if not config.im_select_command and vim.g.im_select_command then
		config.im_select_command = vim.g.im_select_command
	end
	if not config.im_select_default and vim.g.im_select_default then
		config.im_select_default = vim.g.im_select_default
	end
	if not config.im_select_native_im and vim.g.im_select_native_im then
		config.im_select_native_im = vim.g.im_select_native_im
	end
	if not config.im_select_get_im_cmd and vim.g.im_select_get_im_cmd then
		config.im_select_get_im_cmd = vim.g.im_select_get_im_cmd
	end
	if not config.ImSelectSetImCmd and vim.g.ImSelectSetImCmd then
		config.ImSelectSetImCmd = vim.g.ImSelectSetImCmd
	end
	if not config.ImSelectGetImCallback and vim.g.ImSelectGetImCallback then
		config.ImSelectGetImCallback = vim.g.ImSelectGetImCallback
	end
	if not config.im_select_switch_timeout and vim.g.im_select_switch_timeout then
		config.im_select_switch_timeout = vim.g.im_select_switch_timeout
	end
	if not config.im_select_enable_focus_events and vim.g.im_select_enable_focus_events then
		config.im_select_enable_focus_events = vim.g.im_select_enable_focus_events
	end
	if config.im_select_enable_cmd_line == nil and vim.g.im_select_enable_cmd_line ~= nil then
		config.im_select_enable_cmd_line = vim.g.im_select_enable_cmd_line
	end
	if config.im_select_enable_for_gvim == nil and vim.g.im_select_enable_for_gvim ~= nil then
		config.im_select_enable_for_gvim = vim.g.im_select_enable_for_gvim
	end

	return config
end

-- 设置平台默认配置
M.set_platform_defaults = function(config)
	local os_type = determine_os()

	-- 如果用户已经配置了 get_im_cmd 和 set_im_cmd，则跳过自动检测
	if config.im_select_get_im_cmd and config.ImSelectSetImCmd then
		-- 仍然要确保 ImSelectGetImCallback 有默认值
		if not config.ImSelectGetImCallback then
			config.ImSelectGetImCallback = function(status, stdout, stderr)
				return stdout
			end
		end
		return config
	end

	-- Windows / WSL
	if os_type == "Windows" or os_type == "WSL" then
		if not config.im_select_command then
			config.im_select_command = "im-select.exe"
		end
		if not config.im_select_default then
			config.im_select_default = "1033"
		end
		if not config.im_select_get_im_cmd then
			config.im_select_get_im_cmd = { config.im_select_command }
		end
		if not config.ImSelectSetImCmd then
			config.ImSelectSetImCmd = function(key)
				return { config.im_select_command, key }
			end
		end
		-- macOS
	elseif os_type == "macOS" then
		if not config.im_select_command then
			config.im_select_command = "im-select"
		end
		if not config.im_select_default then
			config.im_select_default = "com.apple.keylayout.ABC"
		end
		if not config.im_select_get_im_cmd then
			config.im_select_get_im_cmd = { config.im_select_command }
		end
		if not config.ImSelectSetImCmd then
			config.ImSelectSetImCmd = function(key)
				return { config.im_select_command, key }
			end
		end
		-- Linux
	elseif os_type == "Linux" then
		if vim.fn.executable("fcitx5-remote") == 1 then
			if not config.im_select_default then
				config.im_select_default = "1"
			end
			if not config.im_select_get_im_cmd then
				config.im_select_get_im_cmd = { "fcitx5-remote" }
			end
			if not config.ImSelectSetImCmd then
				config.ImSelectSetImCmd = function(key)
					if key == "1" then
						return { "fcitx5-remote", "-c" }
					elseif key == "2" then
						return { "fcitx5-remote", "-o" }
					else
						error("invalid im key")
					end
				end
			end
		elseif vim.fn.executable("fcitx-remote") == 1 then
			if not config.im_select_default then
				config.im_select_default = "1"
			end
			if not config.im_select_get_im_cmd then
				config.im_select_get_im_cmd = { "fcitx-remote" }
			end
			if not config.ImSelectSetImCmd then
				config.ImSelectSetImCmd = function(key)
					if key == "1" then
						return { "fcitx-remote", "-c" }
					elseif key == "2" then
						return { "fcitx-remote", "-o" }
					else
						error("invalid im key")
					end
				end
			end
		elseif vim.env.XDG_CURRENT_DESKTOP and vim.env.XDG_CURRENT_DESKTOP:lower():match("gnome") then
			if vim.env.GTK_IM_MODULE == "ibus" or vim.env.QT_IM_MODULE == "ibus" then
				if not config.im_select_default then
					config.im_select_default = "0"
				end
				if not config.im_select_get_im_cmd then
					config.im_select_get_im_cmd = {
						"gdbus",
						"call",
						"--session",
						"--dest",
						"org.gnome.Shell",
						"--object-path",
						"/org/gnome/Shell",
						"--method",
						"org.gnome.Shell.Eval",
						"imports.ui.status.keyboard.getInputSourceManager()._mruSources[0].index",
					}
				end
				if not config.ImSelectSetImCmd then
					config.ImSelectSetImCmd = function(key)
						return {
							"gdbus",
							"call",
							"--session",
							"--dest",
							"org.gnome.Shell",
							"--object-path",
							"/org/gnome/Shell",
							"--method",
							"org.gnome.Shell.Eval",
							"imports.ui.status.keyboard.getInputSourceManager().inputSources[" .. key .. "].activate()",
						}
					end
				end
				if not config.ImSelectGetImCallback then
					config.ImSelectGetImCallback = function(status, stdout, stderr)
						local i = stdout:find(",") + 3
						local j = stdout:find(")") - 1
						return stdout:sub(i, j)
					end
				end
			end
		else
			-- 尝试其他 Linux 输入法框架
			if vim.fn.executable("fcitx5-remote") == 1 then
				if not config.im_select_default then
					config.im_select_default = "1"
				end
				if not config.im_select_get_im_cmd then
					config.im_select_get_im_cmd = { "fcitx5-remote" }
				end
				if not config.ImSelectSetImCmd then
					config.ImSelectSetImCmd = function(key)
						if key == "1" then
							return { "fcitx5-remote", "-c" }
						elseif key == "2" then
							return { "fcitx5-remote", "-o" }
						else
							error("invalid im key")
						end
					end
				end
			elseif vim.fn.executable("fcitx-remote") == 1 then
				if not config.im_select_default then
					config.im_select_default = "1"
				end
				if not config.im_select_get_im_cmd then
					config.im_select_get_im_cmd = { "fcitx-remote" }
				end
				if not config.ImSelectSetImCmd then
					config.ImSelectSetImCmd = function(key)
						if key == "1" then
							return { "fcitx-remote", "-c" }
						elseif key == "2" then
							return { "fcitx-remote", "-o" }
						else
							error("invalid im key")
						end
					end
				end
			elseif vim.fn.executable("ibus") == 1 then
				if not config.im_select_default then
					config.im_select_default = "xkb:us::eng"
				end
				if not config.im_select_get_im_cmd then
					config.im_select_get_im_cmd = { "ibus", "engine" }
				end
				if not config.ImSelectSetImCmd then
					config.ImSelectSetImCmd = function(key)
						return { "ibus", "engine", key }
					end
				end
			end
		end
	end

	-- 默认回调函数
	if not config.ImSelectGetImCallback then
		config.ImSelectGetImCallback = function(status, stdout, stderr)
			return stdout
		end
	end

	return config
end

-- 检查是否应该启用插件
M.should_enable = function(config)
	-- 检查是否有必要的命令
	if not config.im_select_get_im_cmd or not config.ImSelectSetImCmd then
		return false
	end

	return true
end

return M
