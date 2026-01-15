# fenghen-im-select.nvim

> 源码翻译自 [vim-im-select](https://github.com/brglng/vim-im-select)  
> 只添加一个功能：切换插入模式时，检测光标左侧字符是否是中文：
> - 如果是，自动切换到中文输入法（vim.g.im_select_native_im）
> - 否则切换到默认输入法（vim.g.im_select_default_im）

**动机**：
- 想扩展 im-select 实现智能判断，成功了，但缺少了很多事件自动切换；
- 想扩展 vim-im-select 实现智能判断，但 vimscript 语法 AI 总是实现错误
- 所以使用lua语言翻译 vim-im-select，再扩展实现智能判断

## 特性

- 完整的事件支持：Insert/CmdLine/Term/Focus/VimLeavePre
- 模式感知：区分普通模式和编辑模式的焦点处理
- 异步任务：使用 vim.loop.spawn 实现非阻塞切换
- 焦点防抖：防止输入法命令窃取焦点导致循环触发
- 跨平台支持：macOS/Windows/WSL/Linux (fcitx5/fcitx/ibus/gnome)
- GUI/终端适配：VimLeavePre 不同处理逻辑
- 完全兼容 vim-im-select 的所有配置项

## 安装

使用 lazy.nvim：

```lua
return {
  "hughfenghen/fenghen-im-select.nvim",
  config = function()
    -- macOS 配置
    if vim.fn.has "mac" == 1 then
      vim.g.im_select_get_im_cmd = { "macism" }
      vim.g.ImSelectSetImCmd = function(key)
        local cmd = { "macism", key }
        return cmd
      end

      vim.g.im_select_default = "com.apple.keylayout.ABC"
      -- 本地输入法, 这里配置的是微信输入法
      vim.g.im_select_native_im = "com.tencent.inputmethod.wetype.pinyin"
    elseif vim.fn.has "win32" == 1 then
      vim.g.im_select_get_im_cmd = { "im-select.exe" }
      vim.g.im_select_default = "1033"
      -- windows 系统没试过
    end

    vim.g.im_select_switch_timeout = 100
    vim.g.im_select_enable_focus_events = 1
    vim.g.im_select_enable_cmd_line = 1

    local im_select = require "im_select.init"
    im_select.setup()
  end,
}
```

## 配置

### setup() 选项

```lua
require("im_select.init").setup({
  -- 获取输入法命令，默认自动检测
  im_select_get_im_cmd = nil,

  -- 设置输入法命令（函数类型），默认自动检测
  ImSelectSetImCmd = nil,

  -- 默认输入法标识符，默认自动检测
  im_select_default = nil,

  -- 解析输出回调函数，默认自动检测
  ImSelectGetImCallback = nil,

  -- 焦点事件防抖超时（毫秒），默认 50
  im_select_switch_timeout = 50,

  -- 是否启用焦点事件，默认 1（启用）
  im_select_enable_focus_events = 1,

  -- 是否启用命令行模式，默认 1（启用）
  im_select_enable_cmd_line = 1,

  -- 是否在 GVim 中启用，默认 0（禁用）
  im_select_enable_for_gvim = 0,
})
```

### 平台默认值

#### macOS

```lua
-- 自动检测
im_select_get_im_cmd = { "im-select" }
ImSelectSetImCmd = function(key) return { "im-select", key } end
im_select_default = "com.apple.keylayout.ABC"
```

#### Windows / WSL

```lua
-- 自动检测
im_select_get_im_cmd = { "im-select.exe" }
ImSelectSetImCmd = function(key) return { "im-select.exe", key } end
im_select_default = "1033"
```

#### Linux (fcitx5)

```lua
-- 自动检测
im_select_get_im_cmd = { "fcitx5-remote" }
ImSelectSetImCmd = function(key)
  if key == "1" then return { "fcitx5-remote", "-c" }
  elseif key == "2" then return { "fcitx5-remote", "-o" }
  end
end
im_select_default = "1"
```

#### Linux (fcitx)

```lua
-- 自动检测
im_select_get_im_cmd = { "fcitx-remote" }
ImSelectSetImCmd = function(key)
  if key == "1" then return { "fcitx-remote", "-c" }
  elseif key == "2" then return { "fcitx-remote", "-o" }
  end
end
im_select_default = "1"
```

#### Linux (ibus)

```lua
-- 自动检测
im_select_get_im_cmd = { "ibus", "engine" }
ImSelectSetImCmd = function(key) return { "ibus", "engine", key } end
im_select_default = "xkb:us::eng"
```

#### Linux (GNOME + ibus)

```lua
-- 自动检测（需要环境变量 XDG_CURRENT_DESKTOP 包含 "gnome"）
im_select_get_im_cmd = {
  "gdbus", "call", "--session",
  "--dest", "org.gnome.Shell",
  "--object-path", "/org/gnome/Shell",
  "--method", "org.gnome.Shell.Eval",
  "imports.ui.status.keyboard.getInputSourceManager()._mruSources[0].index"
}
ImSelectSetImCmd = function(key)
  return {
    "gdbus", "call", "--session",
    "--dest", "org.gnome.Shell",
    "--object-path", "/org/gnome/Shell",
    "--method", "org.gnome.Shell.Eval",
    "imports.ui.status.keyboard.getInputSourceManager().inputSources[" .. key .. "].activate()"
  }
end
ImSelectGetImCallback = function(status, stdout, stderr)
  local i = stdout:find(",") + 3
  local j = stdout:find(")") - 1
  return stdout:sub(i, j)
end
im_select_default = "0"
```

### 使用 vim.g 配置（兼容 vim-im-select）

```lua
vim.g.im_select_default = "com.apple.keylayout.ABC"
vim.g.im_select_enable_focus_events = 1
vim.g.im_select_enable_cmd_line = 1
```

## 工作原理

### 事件触发时机

| 事件 | 触发条件 | 行为 |
|------|---------|------|
| InsertEnter | 进入插入模式 | 根据光标左侧字符判断 |
| CmdLineEnter | 进入命令行模式 | 恢复之前的输入法 |
| TermEnter | 进入终端模式 | 恢复之前的输入法 |
| InsertLeave | 离开插入模式 | 保存当前输入法，切换到默认 |
| CmdLineLeave | 离开命令行模式 | 保存当前输入法，切换到默认 |
| TermLeave | 离开终端模式 | 保存当前输入法，切换到默认 |
| FocusGained | 获得焦点（仅普通模式） | 切换到默认输入法 |
| FocusLost | 失去焦点（仅普通模式） | 恢复之前的输入法 |
| VimLeavePre | 退出 Vim | GUI恢复之前/终端切换默认 |

### 焦点事件防抖机制

某些输入法切换命令（如 gdbus）会窃取焦点，导致 FocusLost 和 FocusGained 事件循环触发。

插件实现了防抖机制：
1. 执行切换命令前临时禁用焦点事件
2. 设置定时器（默认 50ms）后恢复
3. 在此期间不响应焦点事件

### 模式判断

在 FocusGained/FocusLost 事件中，只对普通模式进行处理，忽略插入/命令/终端等模式。

```lua
local function is_insert_or_cmdline_mode()
    local mode = vim.fn.mode()
    return mode:match("^[ciRsSt]$")
end
```

## 命令

- `:ImSelectEnable` - 启用插件
- `:ImSelectDisable` - 禁用插件

## 与 im-select.nvim 的区别

| 特性 | fenghen-im-select.nvim | im-select.nvim |
|------|----------------------|---------------|
| CmdLineEnter/Leave 事件 | ✅ 支持 | ❌ 不支持 |
| TermEnter/Leave 事件 | ✅ 支持 | ❌ 不支持 |
| FocusGained/Lost 事件 | ✅ 支持 | ❌ 不支持 |
| VimLeavePre 事件 | ✅ 支持 | ❌ 不支持 |
| 焦点防抖机制 | ✅ 支持 | ❌ 不支持 |
| 模式感知 | ✅ 支持 | ❌ 不支持 |
| GNOME Shell 支持 | ✅ 支持 | ❌ 不支持 |
| 异步任务 | ✅ vim.loop.spawn | ✅ vim.loop.spawn |

## 参考

- [vim-im-select](https://github.com/brglng/vim-im-select) - 原始 Vim script 实现
- [im-select.nvim](https://github.com/keaising/im-select.nvim) - 早期的 Neovim Lua 实现

## License

MIT
