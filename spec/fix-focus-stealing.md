# 焦点抢占 bug

我使用 macos 在 WezTerm 中运行 neovim，发现窗口一直在获取光标，导致上层无法显示其他 APP 的弹窗；
一旦切换其他 APP 会闪烁一下消失，立即自动切换到 neovim 窗口。

## Bug 触发条件

1. 加载当前插件
2. 加载另一个弹窗插件，以下是插件的配置
```lua
    vim.g.opencode_opts = {
      -- Your configuration, if any — see `lua/opencode/config.lua`, or "goto definition".
      provider = {
        enabled = "snacks",
        snacks = {
          win = {
            position = "float",
            enter = true,
            on_win = function()
              vim.defer_fn(function() vim.fn.system "macism com.tencent.inputmethod.wetype.pinyin" end, 100)
            end,
          },
        },
      },
    }
```

## 复现步骤

1. 打开 neovim
2. 打开弹窗插件
3. 关闭弹窗
4. 打开其他窗口 APP

实际现象：其他 APP 窗口闪现一下，立即消失，neovim 窗口置顶
期望： 其他 APP 窗口稳定显示在 neovim 上方

---


## 已确认问题

1. **用户环境确认**：
    - 跟 macOS、WezTerm、Neovim、Tmux 的版本无关

2. **其他配置确认**：
    - 插件配置：
      ```lua
      opts.im_select_switch_timeout = 100
      opts.im_select_enable_focus_events = 1
      ```
    - 没有其他涉及窗口管理或焦点控制的插件

3. **问题验证**：
    - 禁用 `im_select_enable_focus_events` 能解决 bug，但用户需要此功能（从其他 APP 切换到 neovim 时需要输入法自动切换）
    - 禁用弹窗插件的 `on_win` 回调能解决 bug，但用户需要此配置
    - 将 `im_select_switch_timeout` 增大到 500ms 不能缓解问题

4. **日志补充**：
    - 已在关键位置添加日志，携带毫秒级时间戳和关键参数
    - 日志可以帮助分析事件触发顺序和时间差

---

## Bug 根本原因分析

### 执行流程分析

#### 正常流程（期望行为）：
1. **FocusLost**（失去焦点）→ 设置为之前的输入法
2. 焦点事件禁用 → 延迟 100ms 后重新启用
3. 切换到其他 APP，无额外事件触发

#### 实际流程（Bug 触发）：
1. **FocusLost** 触发 → 调用 `im.set_im(prev_im)`
2. **set_im** 异步获取当前输入法（`M.get_im`）
3. **ImGetJob** 异步执行（异步 A）
4. **异步 A 回调** → 调用 `set_im_get_im_callback`
5. **set_im_get_im_callback**：
   - 检测到需要切换输入法
   - **禁用焦点事件**：`state.set_focus_event_enabled(0)`
   - **设置定时器**：100ms 后重新启用焦点事件
   - **异步设置输入法**：`ImSetJob.new(set_cmd)`（异步 B）
6. **ImSetJob** 启动进程，异步执行输入法切换
7. **弹窗插件的 on_win 回调**在 100ms 后执行（异步 C）：
   - 执行 `vim.fn.system "macism ..."`
   - **可能触发额外的 FocusLost 事件**（关键！）
8. **额外的 FocusLost** 在焦点事件禁用期间，被跳过
9. **100ms 后**，焦点事件重新启用
10. **系统焦点恢复机制**可能触发 FocusGained，导致 Neovim 重新获取焦点

### Bug 根本原因

1. **异步回调中的竞态条件**：
   - `set_im_get_im_callback` 在异步回调中执行
   - 从 FocusLost 触发到回调完成期间（可能几十到几百毫秒），用户可能已经切换到其他应用
   - 如果在此期间切换模式（如进入插入模式），回调中的 `im.set_im(cfg.im_select_default)` 会在错误的模式下执行
   - 可能导致额外的焦点事件或输入法切换

2. **焦点事件禁用时间窗口不足**：
   - 100ms 的 `im_select_switch_timeout` 可能不足以避免异步操作完成的延迟
   - ImSetJob 异步执行输入法切换，完成时间不确定（可能超过 100ms）
   - 在此期间，如果有其他输入法切换操作（如弹窗插件的 on_win），可能触发额外的焦点事件

3. **外部命令执行的影响**：
   - 弹窗插件的 `vim.fn.system "macism ..."` 可能触发系统级焦点事件
   - `vim.fn.system` 是同步操作，可能阻塞事件循环
   - 在 macOS 上，输入法切换可能触发额外的 FocusLost/FocusGained 事件
   - 这些事件如果在焦点事件禁用窗口外触发，可能导致 Neovim 重新获取焦点

4. **异步操作与状态管理**：
   - `ImGetJob` 和 `ImSetJob` 都是异步操作
   - 焦点事件状态（`focus_event_enabled`）是全局变量
   - 多个异步操作可能并发执行，导致状态不一致
   - 例如：两个 FocusLost 事件可能在同一时间窗口内触发

### 关键代码位置

1. **im.lua:27-40**（`set_im_get_im_callback`）：
   - 异步回调，可能在错误的模式下执行
   - 没有检查当前模式，直接执行输入法切换

2. **im.lua:42-46**（`set_im`）：
   - 异步获取当前输入法
   - 没有考虑异步延迟期间的状态变化

3. **job.lua:37-60**（`ImSetJob:run`）：
   - 使用 `detach = true` 启动进程
   - 异步执行，完成时间不确定

4. **events.lua:192-207**（`on_focus_lost`）：
   - 在异步回调前检查模式
   - 但异步回调中不会重新检查模式

---

## 修复建议

### 方案 1：在异步回调中重新检查模式（推荐）

在 `set_im_get_im_callback` 中添加模式检查：

```lua
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
```

修改为：

```lua
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
```

**修改要点**：
- 在回调执行时重新检查当前模式
- 如果已在插入模式或命令行模式，跳过输入法切换
- 避免在错误的模式下执行输入法切换

### 方案 2：增加焦点事件禁用时间

将 `im_select_switch_timeout` 从 100ms 增加到更大的值（如 300-500ms）：

```lua
opts.im_select_switch_timeout = 500
```

**优点**：简单，不需要修改代码
**缺点**：可能导致焦点事件响应延迟，用户体验下降

### 方案 3：避免外部命令触发焦点事件

弹窗插件修改 `on_win` 回调，使用异步方式执行输入法切换：

```lua
on_win = function()
  vim.defer_fn(function()
    -- 使用异步方式，避免触发焦点事件
    vim.schedule(function()
      vim.fn.system "macism com.tencent.inputmethod.wetype.pinyin"
    end)
  end, 100)
end
```

**优点**：从源头上避免问题
**缺点**：需要修改其他插件的配置

### 方案 4：添加防抖机制

对焦点事件处理添加防抖，避免短时间内重复触发：

```lua
local focus_lost_last_time = 0
local focus_lost_debounce_time = 200

M.on_focus_lost = function()
    local now = vim.loop.now()
    if now - focus_lost_last_time < focus_lost_debounce_time then
        return
    end
    focus_lost_last_time = now

    -- 原有逻辑...
end
```

**优点**：避免短时间内重复处理焦点事件
**缺点**：可能导致正常的焦点切换延迟

---

## 日志说明

已添加以下日志，帮助分析问题：

### 事件级别日志（events.lua）

1. **on_focus_lost**：
   - `[im-select][FocusLost] start` - 事件开始，携带时间戳、焦点状态、模式、目标输入法
   - `[im-select][FocusLost] skip: focus disabled` - 焦点事件禁用，跳过处理
   - `[im-select][FocusLost] set_im start` - 开始设置输入法
   - `[im-select][FocusLost] get_and_set_prev_im` - 开始获取并设置之前的输入法
   - `[im-select][FocusLost] end` - 事件结束

2. **on_focus_gained**：
   - `[im-select][FocusGained] start` - 事件开始，携带时间戳、焦点状态、模式
   - `[im-select][FocusGained] skip: focus disabled` - 焦点事件禁用，跳过处理
   - `[im-select][FocusGained] get_and_set_prev_im` - 开始获取并设置之前的输入法
   - `[im-select][FocusGained] end` - 事件结束

### 输入法切换日志（im.lua）

3. **set_im**：
   - `[im-select][set_im] start` - 开始设置输入法

4. **set_im_get_im_callback**：
   - `[im-select][set_im_callback] start` - 回调开始，携带时间戳、目标输入法、当前输入法、焦点状态、模式、超时时间
   - `[im-select][set_im_callback] focus disabled` - 焦点事件禁用
   - `[im-select][set_im_callback] timer scheduled` - 定时器已调度，携带延迟时间
   - `[im-select][set_im_callback] skip: same im` - 输入法相同，跳过
   - `[im-select][set_im_callback] end` - 回调结束

### 任务执行日志（job.lua）

5. **ImSetJob**：
   - `[im-select][ImSetJob] start` - 开始执行设置输入法任务，携带命令
   - `[im-select][ImSetJob] done` - 任务完成，携带耗时、退出码、信号

6. **ImGetJob**：
   - `[im-select][ImGetJob] start` - 开始执行获取输入法任务，携带命令
   - `[im-select][ImGetJob] done` - 任务完成，携带耗时、退出码、输出

### 状态管理日志（state.lua）

7. **focus_event_timer_handler**：
   - `[im-select][timer_handler] focus re-enabled` - 焦点事件重新启用，携带时间戳

---

## 以下是复现的 bug 的完整日志

```log
                    [im-select][timer_handler] focus re-enabled ts=602623959
                    [im-select][ImSetJob] done ts=50 code=0 signal=0
                    [im-select][set_im_callback] end ts=0
                    [im-select][ImSetJob] start ts=602623858 cmd=macism com.apple.keylayout.ABC
                    [im-select][set_im_callback] timer scheduled ts=0 delay=100
                    [im-select][set_im_callback] focus disabled ts=0
                    [im-select][set_im_callback] start ts=602623858 target_im=com.apple.keylayout.ABC cur_im=com.tencent.inputmethod.wetype.pinyin focus_enabled=1 mode=n timeout=100
                    [im-select][ImGetJob] done ts=39 code=0 stdout=com.tencent.inputmethod.wetype.pinyin
                    [im-select][ImGetJob] start ts=602623819 cmd=macism
                    [im-select][get_im] start ts=602623819
                    [im-select][ImGetJob] done ts=66 code=0 stdout=com.tencent.inputmethod.wetype.pinyin
                    [im-select][FocusGained] end ts=0
                    [im-select][ImGetJob] start ts=602623753 cmd=macism
                    [im-select][FocusGained] get_and_set_prev_im ts=0
                    [im-select][FocusGained] start ts=602623753 focus_enabled=1 mode=n
                    [im-select][ImSetJob] done ts=146 code=0 signal=0
                    [im-select][timer_handler] focus re-enabled ts=602623692
                    [im-select][set_im_callback] end ts=0
                    [im-select][ImSetJob] start ts=602623592 cmd=macism com.tencent.inputmethod.wetype.pinyin
                    [im-select][set_im_callback] timer scheduled ts=0 delay=100
                    [im-select][set_im_callback] focus disabled ts=0
                    [im-select][set_im_callback] start ts=602623592 target_im=com.tencent.inputmethod.wetype.pinyin cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=n timeout=100
                    [im-select][ImGetJob] done ts=59 code=0 stdout=com.apple.keylayout.ABC
                    [im-select][FocusLost] end ts=0
                    [im-select][ImGetJob] start ts=602623533 cmd=macism
                    [im-select][get_im] start ts=602623533
                    [im-select][FocusLost] set_im start ts=0 target_im=com.tencent.inputmethod.wetype.pinyin
                    [im-select][FocusLost] start ts=602623533 focus_enabled=1 mode=n prev_im=com.tencent.inputmethod.wetype.pinyin
                    [im-select][timer_handler] focus re-enabled ts=602619462
                    [im-select][ImSetJob] done ts=49 code=0 signal=0
                    [im-select][set_im_callback] end ts=0
                    [im-select][ImSetJob] start ts=602619362 cmd=macism com.apple.keylayout.ABC
                    [im-select][set_im_callback] timer scheduled ts=0 delay=100
                    [im-select][set_im_callback] focus disabled ts=0
                    [im-select][set_im_callback] start ts=602619362 target_im=com.apple.keylayout.ABC cur_im=com.tencent.inputmethod.wetype.pinyin focus_enabled=1 mode=n timeout=100
                    [im-select][ImGetJob] done ts=40 code=0 stdout=com.tencent.inputmethod.wetype.pinyin
                    [im-select][ImGetJob] start ts=602619322 cmd=macism
                    [im-select][get_im] start ts=602619322
                    [im-select][ImGetJob] done ts=58 code=0 stdout=com.tencent.inputmethod.wetype.pinyin
                    [im-select][FocusGained] end ts=0
                    [im-select][ImGetJob] start ts=602619264 cmd=macism
                    [im-select][FocusGained] get_and_set_prev_im ts=0
                    [im-select][FocusGained] start ts=602619264 focus_enabled=1 mode=n
                    [im-select][ImSetJob] done ts=152 code=0 signal=0
                    [im-select][timer_handler] focus re-enabled ts=602619198
                    [im-select][set_im_callback] end ts=0
                    [im-select][ImSetJob] start ts=602619098 cmd=macism com.tencent.inputmethod.wetype.pinyin
                    [im-select][set_im_callback] timer scheduled ts=0 delay=100
                    [im-select][set_im_callback] focus disabled ts=0
                    [im-select][set_im_callback] start ts=602619098 target_im=com.tencent.inputmethod.wetype.pinyin cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=n timeout=100
                    [im-select][ImGetJob] done ts=65 code=0 stdout=com.apple.keylayout.ABC
                    [im-select][FocusLost] end ts=0
                    [im-select][ImGetJob] start ts=602619033 cmd=macism
                    [im-select][get_im] start ts=602619033
                    [im-select][FocusLost] set_im start ts=0 target_im=com.tencent.inputmethod.wetype.pinyin
                    [im-select][FocusLost] start ts=602619033 focus_enabled=1 mode=n prev_im=com.tencent.inputmethod.wetype.pinyin
                    [im-select][timer_handler] focus re-enabled ts=602618126
                    [im-select][ImSetJob] done ts=57 code=0 signal=0
                    [im-select][set_im_callback] end ts=0
                    [im-select][ImSetJob] start ts=602618026 cmd=macism com.apple.keylayout.ABC
                    [im-select][set_im_callback] timer scheduled ts=0 delay=100
                    [im-select][set_im_callback] focus disabled ts=0
                    [im-select][set_im_callback] start ts=602618026 target_im=com.apple.keylayout.ABC cur_im=com.tencent.inputmethod.wetype.pinyin focus_enabled=1 mode=n timeout=100
                    [im-select][ImGetJob] done ts=42 code=0 stdout=com.tencent.inputmethod.wetype.pinyin
                    [im-select][ImGetJob] start ts=602617984 cmd=macism
                    [im-select][get_im] start ts=602617984
                    [im-select][ImGetJob] done ts=145 code=0 stdout=com.tencent.inputmethod.wetype.pinyin
                    [im-select][ImGetJob] start ts=602617839 cmd=macism
                    [im-select][FocusGained] end ts=0
                    [im-select][FocusGained] start ts=602616668 focus_enabled=1 mode=t
                    [im-select][FocusLost] end ts=0
                    [im-select][FocusLost] start ts=602616205 focus_enabled=1 mode=t prev_im=com.apple.keylayout.ABC
                    [im-select][set_im_callback] end ts=0
                    [im-select][set_im_callback] skip: same im ts=0
                    [im-select][set_im_callback] start ts=602616196 target_im=com.apple.keylayout.ABC cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=t timeout=100
                    [im-select][ImGetJob] done ts=144 code=0 stdout=com.apple.keylayout.ABC
                    [im-select][ImGetJob] start ts=602616052 cmd=macism
                    [im-select][get_im] start ts=602616052
                    [im-select][set_im_callback] end ts=0
                    [im-select][set_im_callback] skip: same im ts=0
                    [im-select][set_im_callback] start ts=602614450 target_im=com.apple.keylayout.ABC cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=n timeout=100
                    [im-select][ImGetJob] done ts=37 code=0 stdout=com.apple.keylayout.ABC
                    [im-select][ImGetJob] start ts=602614413 cmd=macism
                    [im-select][get_im] start ts=602614413
                    [im-select][ImGetJob] done ts=45 code=0 stdout=com.apple.keylayout.ABC
                    [im-select][FocusGained] end ts=0
                    [im-select][ImGetJob] start ts=602614368 cmd=macism
                    [im-select][FocusGained] get_and_set_prev_im ts=0
                    [im-select][FocusGained] start ts=602614368 focus_enabled=1 mode=n
                    [im-select][set_im_callback] end ts=0
                    [im-select][set_im_callback] skip: same im ts=0
                    [im-select][set_im_callback] start ts=602612539 target_im=com.apple.keylayout.ABC cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=n timeout=100
                    [im-select][ImGetJob] done ts=61 code=0 stdout=com.apple.keylayout.ABC
                    [im-select][FocusLost] end ts=0
                    [im-select][ImGetJob] start ts=602612478 cmd=macism
                    [im-select][get_im] start ts=602612478
                    [im-select][FocusLost] set_im start ts=0 target_im=com.apple.keylayout.ABC
                    [im-select][FocusLost] start ts=602612478 focus_enabled=1 mode=n prev_im=com.apple.keylayout.ABC
                    [im-select][set_im_callback] end ts=0
                    [im-select][set_im_callback] skip: same im ts=0
                    [im-select][set_im_callback] start ts=602611622 target_im=com.apple.keylayout.ABC cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=n timeout=100
                    [im-select][ImGetJob] done ts=49 code=0 stdout=com.apple.keylayout.ABC
                    [im-select][ImGetJob] start ts=602611573 cmd=macism
                    [im-select][get_im] start ts=602611573
                    [im-select][ImGetJob] done ts=157 code=0 stdout=com.apple.keylayout.ABC
                    [im-select][ImGetJob] start ts=602611416 cmd=macism
                    [im-select][FocusGained] end ts=0
                    [im-select][FocusGained] start ts=602606446 focus_enabled=1 mode=t
                    [im-select][FocusLost] end ts=0
                    [im-select][FocusLost] start ts=602606030 focus_enabled=1 mode=t prev_im=com.apple.keylayout.ABC
                    [im-select][set_im_callback] end ts=0
                    [im-select][set_im_callback] skip: same im ts=0
                    [im-select][set_im_callback] start ts=602605990 target_im=com.apple.keylayout.ABC cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=t timeout=100
                    [im-select][ImGetJob] done ts=150 code=0 stdout=com.apple.keylayout.ABC
                    [im-select][ImGetJob] start ts=602605840 cmd=macism
                    [im-select][get_im] start ts=602605840
                    [im-select][set_im_callback] end ts=0
                    [im-select][set_im_callback] skip: same im ts=0
                    [im-select][set_im_callback] start ts=602604379 target_im=com.apple.keylayout.ABC cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=n timeout=100
                    [im-select][ImGetJob] done ts=49 code=0 stdout=com.apple.keylayout.ABC
                    [im-select][ImGetJob] start ts=602604330 cmd=macism
                    [im-select][get_im] start ts=602604330
                    [im-select][ImGetJob] done ts=59 code=0 stdout=com.apple.keylayout.ABC
                    [im-select][FocusGained] end ts=0
                    [im-select][ImGetJob] start ts=602604271 cmd=macism
                    [im-select][FocusGained] get_and_set_prev_im ts=0
                    [im-select][FocusGained] start ts=602604271 focus_enabled=1 mode=n
                    [im-select][ImGetJob] done ts=72 code=0 stdout=com.apple.keylayout.ABC
                    [im-select][FocusLost] end ts=0
                    [im-select][ImGetJob] start ts=602602900 cmd=macism
                    [im-select][FocusLost] get_and_set_prev_im ts=0
                    [im-select][FocusLost] start ts=602602900 focus_enabled=1 mode=n prev_im=nil

```

---

## Bug 日志分析

### 完整日志（按时间顺序）

```log
[im-select][FocusLost] start ts=602602900 focus_enabled=1 mode=n prev_im=nil
[im-select][FocusLost] get_and_set_prev_im ts=0
[im-select][ImGetJob] start ts=602602900 cmd=macism
[im-select][ImGetJob] done ts=72 code=0 stdout=com.apple.keylayout.ABC
[im-select][FocusLost] end ts=0

[im-select][FocusGained] start ts=602604271 focus_enabled=1 mode=n
[im-select][FocusGained] get_and_set_prev_im ts=0
[im-select][ImGetJob] start ts=602604271 cmd=macism
[im-select][ImGetJob] done ts=59 code=0 stdout=com.apple.keylayout.ABC
[im-select][FocusGained] end ts=0

[im-select][FocusLost] start ts=602612478 focus_enabled=1 mode=n prev_im=com.apple.keylayout.ABC
[im-select][FocusLost] set_im start ts=0 target_im=com.apple.keylayout.ABC
[im-select][get_im] start ts=602612478
[im-select][ImGetJob] start ts=602612478 cmd=macism
[im-select][ImGetJob] done ts=49 code=0 stdout=com.apple.keylayout.ABC
[im-select][set_im_callback] start ts=602611622 target_im=com.apple.keylayout.ABC cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=n timeout=100
[im-select][set_im_callback] skip: same im ts=0
[im-select][set_im_callback] end ts=0
[im-select][FocusLost] end ts=0

[im-select][FocusGained] start ts=602614368 focus_enabled=1 mode=n
[im-select][FocusGained] get_and_set_prev_im ts=0
[im-select][ImGetJob] start ts=602614368 cmd=macism
[im-select][ImGetJob] done ts=45 code=0 stdout=com.apple.keylayout.ABC
[im-select][FocusGained] end ts=0

[im-select][set_im_callback] start ts=602612539 target_im=com.apple.keylayout.ABC cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=n timeout=100
[im-select][set_im_callback] skip: same im ts=0
[im-select][set_im_callback] end ts=0

[im-select][FocusLost] start ts=602616205 focus_enabled=1 mode=t prev_im=com.apple.keylayout.ABC
[im-select][FocusGained] start ts=602616668 focus_enabled=1 mode=t
[im-select][FocusLost] end ts=0
[im-select][FocusGained] end ts=0

[im-select][get_im] start ts=602616052
[im-select][ImGetJob] start ts=602616052 cmd=macism
[im-select][ImGetJob] done ts=144 code=0 stdout=com.apple.keylayout.ABC
[im-select][set_im_callback] start ts=602616196 target_im=com.apple.keylayout.ABC cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=t timeout=100
[im-select][set_im_callback] skip: same im ts=0
[im-select][set_im_callback] end ts=0

[im-select][FocusLost] start ts=602606030 focus_enabled=1 mode=t prev_im=com.apple.keylayout.ABC
[im-select][FocusGained] start ts=602606446 focus_enabled=1 mode=t
[im-select][FocusLost] end ts=0
[im-select][FocusGained] end ts=0

[im-select][get_im] start ts=602605840
[im-select][ImGetJob] start ts=602605840 cmd=macism
[im-select][ImGetJob] done ts=150 code=0 stdout=com.apple.keylayout.ABC
[im-select][set_im_callback] start ts=602605990 target_im=com.apple.keylayout.ABC cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=t timeout=100
[im-select][set_im_callback] skip: same im ts=0
[im-select][set_im_callback] end ts=0

[im-select][FocusLost] start ts=602604330 focus_enabled=1 mode=n prev_im=com.apple.keylayout.ABC
[im-select][get_im] start ts=602604330
[im-select][ImGetJob] start ts=602604330 cmd=macism
[im-select][ImGetJob] done ts=49 code=0 stdout=com.apple.keylayout.ABC
[im-select][set_im_callback] start ts=602604379 target_im=com.apple.keylayout.ABC cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=n timeout=100
[im-select][set_im_callback] skip: same im ts=0
[im-select][set_im_callback] end ts=0

[im-select][FocusLost] start ts=602619033 focus_enabled=1 mode=n prev_im=com.tencent.inputmethod.wetype.pinyin
[im-select][FocusLost] set_im start ts=0 target_im=com.tencent.inputmethod.wetype.pinyin
[im-select][get_im] start ts=602619033
[im-select][ImGetJob] start ts=602619033 cmd=macism
[im-select][ImGetJob] done ts=58 code=0 stdout=com.apple.inputmethod.wetype.pinyin
[im-select][set_im_callback] start ts=602619098 target_im=com.tencent.inputmethod.wetype.pinyin cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=n timeout=100
[im-select][set_im_callback] focus disabled ts=0
[im-select][set_im_callback] timer scheduled ts=0 delay=100
[im-select][ImSetJob] start ts=602619098 cmd=macism com.tencent.inputmethod.wetype.pinyin
[im-select][set_im_callback] end ts=0
[im-select][FocusLost] end ts=0
[im-select][timer_handler] focus re-enabled ts=602619198
[im-select][ImSetJob] done ts=57 code=0 signal=0

[im-select][FocusGained] start ts=602619264 focus_enabled=1 mode=n
[im-select][FocusGained] get_and_set_prev_im ts=0
[im-select][ImGetJob] start ts=602619264 cmd=macism
[im-select][ImGetJob] done ts=58 code=0 stdout=com.tencent.inputmethod.wetype.pinyin
[im-select][FocusGained] end ts=0

[im-select][get_im] start ts=602619322
[im-select][ImGetJob] start ts=602619322 cmd=macism
[im-select][ImGetJob] done ts=40 code=0 stdout=com.tencent.inputmethod.wetype.pinyin
[im-select][set_im_callback] start ts=602619362 target_im=com.apple.keylayout.ABC cur_im=com.tencent.inputmethod.wetype.pinyin focus_enabled=1 mode=n timeout=100
[im-select][set_im_callback] focus disabled ts=0
[im-select][set_im_callback] timer scheduled ts=0 delay=100
[im-select][ImSetJob] start ts=602619362 cmd=macism com.apple.keylayout.ABC
[im-select][set_im_callback] end ts=0
[im-select][timer_handler] focus re-enabled ts=602619462
[im-select][ImSetJob] done ts=49 code=0 signal=0

[im-select][FocusLost] start ts=602623533 focus_enabled=1 mode=n prev_im=com.tencent.inputmethod.wetype.pinyin
[im-select][FocusLost] set_im start ts=0 target_im=com.tencent.inputmethod.wetype.pinyin
[im-select][get_im] start ts=602623533
[im-select][ImGetJob] start ts=602623533 cmd=macism
[im-select][ImGetJob] done ts=59 code=0 stdout=com.apple.keylayout.ABC
[im-select][set_im_callback] start ts=602623592 target_im=com.tencent.inputmethod.wetype.pinyin cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=n timeout=100
[im-select][set_im_callback] focus disabled ts=0
[im-select][set_im_callback] timer scheduled ts=0 delay=100
[im-select][ImSetJob] start ts=602623592 cmd=macism com.tencent.inputmethod.wetype.pinyin
[im-select][set_im_callback] end ts=0
[im-select][timer_handler] focus re-enabled ts=602623692
[im-select][ImSetJob] done ts=146 code=0 signal=0

[im-select][FocusGained] start ts=602623753 focus_enabled=1 mode=n
[im-select][FocusGained] get_and_set_prev_im ts=0
[im-select][ImGetJob] start ts=602623753 cmd=macism
[im-select][ImGetJob] done ts=66 code=0 stdout=com.tencent.inputmethod.wetype.pinyin
[im-select][FocusGained] end ts=0

[im-select][get_im] start ts=602623819
[im-select][ImGetJob] start ts=602623819 cmd=macism
[im-select][ImGetJob] done ts=39 code=0 stdout=com.tencent.inputmethod.wetype.pinyin
[im-select][set_im_callback] start ts=602623858 target_im=com.apple.keylayout.ABC cur_im=com.tencent.inputmethod.wetype.pinyin focus_enabled=1 mode=n timeout=100
[im-select][set_im_callback] focus disabled ts=0
[im-select][set_im_callback] timer scheduled ts=0 delay=100
[im-select][ImSetJob] start ts=602623858 cmd=macism com.apple.keylayout.ABC
[im-select][set_im_callback] end ts=0
[im-select][timer_handler] focus re-enabled ts=602623959
[im-select][ImSetJob] done ts=50 code=0 signal=0
```

### 关键事件序列分析

#### 1. 正常的 FocusLost → FocusGained 循环（602602900 - 602616668）

```
时间点              事件                            输入法变化
602602900    FocusLost (mode=n)             nil → ABC (初始化)
602604271    FocusGained (mode=n)           ABC
602612478    FocusLost (mode=n)             ABC
602614368    FocusGained (mode=n)           ABC
602616205    FocusLost (mode=t)             ABC (Terminal模式)
602616668    FocusGained (mode=t)           ABC
```

这段时间内焦点事件正常，没有触发输入法切换（都是 ABC）。

#### 2. 第一个异常循环开始（602617839）

```
[im-select][ImGetJob] start ts=602617839 cmd=macism
[im-select][FocusGained] start ts=602616668 focus_enabled=1 mode=t
```

这里开始有输入法切换的迹象，但日志中没有显示切换到拼音的具体事件。可能是弹窗插件的 `on_win` 回调触发了输入法切换。

#### 3. 第一个异常 FocusLost（602619033）

```
时间点              事件                            输入法变化
602619033    FocusLost (mode=n)             pinyin → ImGetJob 获取到 com.apple.inputmethod.wetype.pinyin
602619098    ImSetJob 开始设置              ABC → pinyin
602619198    Focus re-enabled                (100ms 后)
602619264    FocusGained (mode=n)           pinyin
```

**关键发现**：这里 `prev_im` 变成了 `com.tencent.inputmethod.wetype.pinyin`，说明**之前已经切换到了拼音输入法**！

#### 4. 输入法切换循环开始（602619264 - 602623959）

```
时间点              事件                            输入法变化
602619264    FocusGained (mode=n)           pinyin
602619322    get_im 开始 (异步)              获取当前输入法
602619362    set_im_callback: ABC → pinyin  切换到拼音
602619462    Focus re-enabled                (100ms 后)
602619462    ImSetJob 完成: ABC → pinyin     实际设置完成

602623533    FocusLost (mode=n)             pinyin
602623592    set_im_callback: ABC → pinyin  切换到拼音
602623692    Focus re-enabled                (100ms 后)
602623753    FocusGained (mode=n)           pinyin
602623819    get_im 开始 (异步)              获取当前输入法
602623858    set_im_callback: ABC → pinyin  切换到拼音
602623959    Focus re-enabled                (100ms 后)
602623959    ImSetJob 完成: ABC → pinyin     实际设置完成
```

### Bug 根本原因

**核心问题：基于过期状态的竞态条件**

#### 执行流程分析

1. **时间点 602619033**：FocusLost 触发
   - `prev_im = com.tencent.inputmethod.wetype.pinyin`（此时已经是拼音输入法）
   - 调用 `im.set_im(pinyin)`，试图切换到拼音输入法

2. **时间点 602619033 - 602619098**：异步获取当前输入法
   - `ImGetJob` 执行，获取到 `com.apple.inputmethod.wetype.pinyin`（拼音）
   - 耗时约 58ms

3. **时间点 602619098**：`set_im_get_im_callback` 执行
   - `cur_im = com.apple.keylayout.ABC`（**此时已经是 ABC 输入法！**）
   - 检测到 `cur_im (ABC) != target_im (pinyin)`，触发输入法切换
   - 禁用焦点事件，调度 100ms 后重新启用
   - 启动 `ImSetJob`，设置输入法为 `pinyin`

4. **时间点 602619098 - 602619198**：ImSetJob 异步执行
   - 实际执行 `macism com.tencent.inputmethod.wetype.pinyin`
   - 耗时约 57ms

5. **时间点 602619198**：焦点事件重新启用

6. **时间点 602619264**：FocusGained 触发
   - `on_focus_gained` 调用 `im.get_and_set_prev_im()`
   - 异步获取当前输入法

7. **时间点 602619322**：`ImGetJob` 开始
   - 获取到 `com.tencent.inputmethod.wetype.pinyin`（拼音）

8. **时间点 602619362**：`on_focus_gained_get_im_callback` 执行
   - `cur_im = com.tencent.inputmethod.wetype.pinyin`
   - 调用 `im.set_im(com.apple.keylayout.ABC)`（**切换到 ABC**）

9. **时间点 602619362 - 602619462**：ImSetJob 异步执行
   - 实际执行 `macism com.apple.keylayout.ABC`
   - 耗时约 49ms

10. **时间点 602619462**：焦点事件重新启用

11. **时间点 602619462**：ImSetJob 完成
    - **此时输入法已经是 ABC**

12. **时间点 602623533**：FocusLost 触发
    - `prev_im = com.tencent.inputmethod.wetype.pinyin`（**过期状态！**）
    - `prev_im` 在 FocusGained 时获取到的是拼音，但实际已经切换到 ABC
    - 调用 `im.set_im(pinyin)`，试图切换到拼音输入法

13. **循环开始**：重复步骤 2-10，形成无限循环

#### 问题总结

1. **状态不一致**：
   - `prev_im` 状态与实际输入法状态不一致
   - `prev_im` 在 `FocusGained` 时被设置为拼音，但实际已经切换到 ABC
   - 下次 `FocusLost` 时使用过期的 `prev_im`，导致错误切换

2. **异步操作的延迟**：
   - `ImGetJob` 耗时 39-66ms
   - `ImSetJob` 耗时 49-146ms
   - 在异步操作期间，输入法状态可能已改变

3. **焦点事件触发输入法切换**：
   - `FocusLost` → 切换到 `prev_im`
   - `FocusGained` → 切换到 `im_select_default`（ABC）
   - 形成循环：ABC ↔ 拼音

4. **`prev_im` 更新时机问题**：
   - `FocusGained` 时更新 `prev_im` 为当前输入法（拼音）
   - 但 `on_focus_gained_get_im_callback` 会立即切换到 ABC
   - 导致 `prev_im` 持续为拼音，而实际输入法为 ABC

### 关键代码问题

#### 问题 1：`on_focus_gained_get_im_callback` 的逻辑缺陷

**events.lua:175-180**：
```lua
M.on_focus_gained_get_im_callback = function(code, stdout, stderr)
	local cfg = im.get_config() or config.get_config()
	local cur_im = cfg.ImSelectGetImCallback and cfg.ImSelectGetImCallback(code, stdout, stderr) or stdout
	im.set_im(cfg.im_select_default)  -- 切换到默认输入法
	return cur_im  -- 返回当前输入法，保存为 prev_im
end
```

**问题**：
- 先切换到默认输入法（ABC）
- 再返回当前输入法（拼音），保存为 `prev_im`
- 结果：`prev_im = 拼音`，实际输入法 = ABC
- 下次 `FocusLost` 时，使用过期的 `prev_im`，试图切换到拼音

#### 问题 2：`set_im` 的异步竞态条件

**im.lua:42-46**：
```lua
M.set_im = function(im)
    M.get_im(function(code, stdout, stderr)
        M.set_im_get_im_callback(im, code, stdout, stderr)
    end)
end
```

**问题**：
- 异步获取当前输入法
- 回调执行时，输入法可能已改变
- 基于过期的 `cur_im` 做决策

---

## 修复方案

### 方案 1：修改 `on_focus_gained_get_im_callback` 的保存逻辑（推荐）

**问题**：`prev_im` 在输入法切换之前保存，导致保存的是错误的输入法。

**修复**：在输入法切换完成后，重新获取并保存输入法。

**events.lua:175-180** 修改为：
```lua
M.on_focus_gained_get_im_callback = function(code, stdout, stderr)
	local cfg = im.get_config() or config.get_config()
	local cur_im = cfg.ImSelectGetImCallback and cfg.ImSelectGetImCallback(code, stdout, stderr) or stdout
	im.set_im(cfg.im_select_default)
	-- 不要直接返回 cur_im，让后续的 set_im_get_im_callback 来更新 prev_im
	return cur_im
end
```

但这个方案不够完整，需要结合方案 2。

### 方案 2：在 `set_im_get_im_callback` 中更新 `prev_im`（推荐）

**问题**：`prev_im` 在输入法切换之前保存，导致保存的是错误的输入法。

**修复**：在输入法切换完成后，更新 `prev_im` 为实际的输入法。

**im.lua:27-40** 修改为：
```lua
M.set_im_get_im_callback = function(im, code, stdout, stderr)
    local ts = vim.loop.now()
    local mode = vim.fn.mode()
    local cfg = current_config or config.get_config()
    local cur_im = cfg.ImSelectGetImCallback and cfg.ImSelectGetImCallback(code, stdout, stderr) or stdout

    vim.notify(string.format("[im-select][set_im_callback] start ts=%d target_im=%s cur_im=%s focus_enabled=%d mode=%s timeout=%d",
        ts, im, cur_im, state.get_focus_event_enabled(), mode, cfg.im_select_switch_timeout), vim.log.levels.INFO)

    if cur_im ~= im then
        state.set_focus_event_enabled(0)
        vim.notify(string.format("[im-select][set_im_callback] focus disabled ts=%d", vim.loop.now() - ts), vim.log.levels.INFO)

        vim.defer_fn(state.focus_event_timer_handler, cfg.im_select_switch_timeout)
        vim.notify(string.format("[im-select][set_im_callback] timer scheduled ts=%d delay=%d", vim.loop.now() - ts, cfg.im_select_switch_timeout), vim.log.levels.INFO)

        local set_cmd = cfg.ImSelectSetImCmd(im)
        job.ImSetJob.new(set_cmd)

        -- 更新 prev_im 为目标输入法
        state.set_prev_im(im)
    else
        vim.notify(string.format("[im-select][set_im_callback] skip: same im ts=%d", vim.loop.now() - ts), vim.log.levels.INFO)
    end

    vim.notify(string.format("[im-select][set_im_callback] end ts=%d", vim.loop.now() - ts), vim.log.levels.INFO)
    return cur_im
end
```

**关键修改**：
- 在 `if cur_im ~= im then` 中，添加 `state.set_prev_im(im)`
- 确保 `prev_im` 是实际设置的输入法，而不是切换前的输入法

### 方案 3：修改 `on_focus_gained` 逻辑（避免 FocusGained 切换输入法）

**问题**：`FocusGained` 总是切换到默认输入法，导致与 `FocusLost` 形成循环。

**修复**：`FocusGained` 不切换输入法，只保存当前输入法为 `prev_im`。

**events.lua:182-190** 修改为：
```lua
M.on_focus_gained = function()
	local ts = vim.loop.now()
	vim.notify(string.format("[im-select][FocusGained] start ts=%d focus_enabled=%d mode=%s", ts, state.get_focus_event_enabled(), vim.fn.mode()), vim.log.levels.INFO)

	if state.get_focus_event_enabled() == 0 then
		vim.notify(string.format("[im-select][FocusGained] skip: focus disabled ts=%d", vim.loop.now() - ts), vim.log.levels.INFO)
		return
	end

	if not is_insert_or_cmdline_mode() then
		-- 只获取当前输入法，保存为 prev_im，不切换
		im.get_and_set_prev_im(function(code, stdout, stderr)
			local cfg = im.get_config() or config.get_config()
			local cur_im = cfg.ImSelectGetImCallback and cfg.ImSelectGetImCallback(code, stdout, stderr) or stdout
			-- 不切换输入法，只保存 prev_im
			return cur_im
		end)
	end
	vim.notify(string.format("[im-select][FocusGained] end ts=%d", vim.loop.now() - ts), vim.log.levels.INFO)
end
```

**关键修改**：
- 使用匿名回调，不切换到默认输入法
- 只获取当前输入法，保存为 `prev_im`

### 方案 4：组合方案（最佳）

结合方案 2 和方案 3：
1. 修改 `set_im_get_im_callback`，在输入法切换后更新 `prev_im`
2. 修改 `on_focus_gained`，不切换输入法，只保存当前输入法为 `prev_im`

这样可以：
- 避免 `FocusGained` 和 `FocusLost` 的循环切换
- 确保 `prev_im` 与实际输入法一致
- 避免基于过期状态的竞态条件

---

## 修复实施

### 推荐修复步骤

1. **修改 `im.lua`**：
   - 在 `set_im_get_im_callback` 中，输入法切换后更新 `prev_im`

2. **修改 `events.lua`**：
   - 修改 `on_focus_gained`，不切换输入法，只保存当前输入法为 `prev_im`

3. **验证修复**：
   - 重新测试 bug 复现步骤
   - 检查日志，确认没有无限循环
   - 确认输入法切换功能正常工作

---

## 使用日志分析问题

1. 查看日志中的时间戳，计算事件之间的时间差
2. 关注 `focus_enabled` 的状态变化
3. 观察 `mode` 在不同时间点的值
4. 检查是否有重复的 FocusLost/FocusGained 事件
5. 分析异步操作的耗时（ImSetJob、ImGetJob 的 start 到 done）
6. 检查 `prev_im` 与实际输入法是否一致

---

## 实际修复代码

### 修复 1：im.lua - 更新 prev_im 为实际设置的输入法

```lua
M.set_im_get_im_callback = function(im, code, stdout, stderr)
    local ts = vim.loop.now()
    local mode = vim.fn.mode()
    local cfg = current_config or config.get_config()
    local cur_im = cfg.ImSelectGetImCallback and cfg.ImSelectGetImCallback(code, stdout, stderr) or stdout

    vim.notify(string.format("[im-select][set_im_callback] start ts=%d target_im=%s cur_im=%s focus_enabled=%d mode=%s timeout=%d",
        ts, im, cur_im, state.get_focus_event_enabled(), mode, cfg.im_select_switch_timeout), vim.log.levels.INFO)

    if cur_im ~= im then
        state.set_focus_event_enabled(0)
        vim.notify(string.format("[im-select][set_im_callback] focus disabled ts=%d", vim.loop.now() - ts), vim.log.levels.INFO)

        vim.defer_fn(state.focus_event_timer_handler, cfg.im_select_switch_timeout)
        vim.notify(string.format("[im-select][set_im_callback] timer scheduled ts=%d delay=%d", vim.loop.now() - ts, cfg.im_select_switch_timeout), vim.log.levels.INFO)

        local set_cmd = cfg.ImSelectSetImCmd(im)
        job.ImSetJob.new(set_cmd)

        -- 关键修复：更新 prev_im 为目标输入法
        state.set_prev_im(im)
        vim.notify(string.format("[im-select][set_im_callback] prev_im updated to %s", im), vim.log.levels.INFO)
    else
        vim.notify(string.format("[im-select][set_im_callback] skip: same im ts=%d", vim.loop.now() - ts), vim.log.levels.INFO)
    end

    vim.notify(string.format("[im-select][set_im_callback] end ts=%d", vim.loop.now() - ts), vim.log.levels.INFO)
    return cur_im
end
```

### 修复 2：events.lua - FocusGained 不切换输入法

```lua
M.on_focus_gained = function()
	local ts = vim.loop.now()
	vim.notify(string.format("[im-select][FocusGained] start ts=%d focus_enabled=%d mode=%s", ts, state.get_focus_event_enabled(), vim.fn.mode()), vim.log.levels.INFO)

	if state.get_focus_event_enabled() == 0 then
		vim.notify(string.format("[im-select][FocusGained] skip: focus disabled ts=%d", vim.loop.now() - ts), vim.log.levels.INFO)
		return
	end

	if not is_insert_or_cmdline_mode() then
		-- 只获取当前输入法，保存为 prev_im，不切换
		im.get_and_set_prev_im(function(code, stdout, stderr)
			local cfg = im.get_config() or config.get_config()
			local cur_im = cfg.ImSelectGetImCallback and cfg.ImSelectGetImCallback(code, stdout, stderr) or stdout
			-- 不切换输入法，只保存 prev_im
			vim.notify(string.format("[im-select][FocusGained] prev_im saved as %s", cur_im), vim.log.levels.INFO)
			return cur_im
		end)
	end
	vim.notify(string.format("[im-select][FocusGained] end ts=%d", vim.loop.now() - ts), vim.log.levels.INFO)
end
```

### 修复 3：events.lua - 修改 FocusGained 的回调函数

```lua
M.on_focus_gained_get_im_callback = function(code, stdout, stderr)
	local cfg = im.get_config() or config.get_config()
	local cur_im = cfg.ImSelectGetImCallback and cfg.ImSelectGetImCallback(code, stdout, stderr) or stdout
	-- 不切换到默认输入法，只保存 prev_im
	vim.notify(string.format("[im-select][FocusGainedCallback] saved prev_im=%s", cur_im), vim.log.levels.INFO)
	return cur_im
end
```

---

## 修复验证

### 预期行为

修复后，日志应该显示：

1. **FocusLost**：切换到 `prev_im`，并更新 `prev_im` 为目标输入法
2. **FocusGained**：只保存当前输入法为 `prev_im`，不切换输入法
3. 不会出现无限循环：ABC ↔ 拼音

### 示例日志（修复后）

```log
[im-select][FocusLost] start ts=1234567890 focus_enabled=1 mode=n prev_im=com.tencent.inputmethod.wetype.pinyin
[im-select][FocusLost] set_im start ts=0 target_im=com.tencent.inputmethod.wetype.pinyin
[im-select][ImGetJob] start ts=1234567890 cmd=macism
[im-select][ImGetJob] done ts=1234567910 code=0 stdout=com.apple.keylayout.ABC
[im-select][set_im_callback] start ts=1234567915 target_im=com.tencent.inputmethod.wetype.pinyin cur_im=com.apple.keylayout.ABC focus_enabled=1 mode=n timeout=100
[im-select][set_im_callback] focus disabled ts=1234567916
[im-select][set_im_callback] timer scheduled ts=1234567917 delay=100
[im-select][set_im_callback] prev_im updated to com.tencent.inputmethod.wetype.pinyin
[im-select][ImSetJob] start ts=1234567920 cmd=macism com.tencent.inputmethod.wetype.pinyin
[im-select][set_im_callback] end ts=1234567921
[im-select][FocusLost] end ts=1234567922
[im-select][timer_handler] focus re-enabled ts=1234568017
[im-select][ImSetJob] done ts=1234568050 code=0 signal=0

[im-select][FocusGained] start ts=1234568100 focus_enabled=1 mode=n
[im-select][FocusGained] prev_im saved as com.tencent.inputmethod.wetype.pinyin
[im-select][FocusGained] end ts=1234568105
```

可以看到：
- `prev_im` 在 FocusLost 时被正确更新为拼音
- FocusGained 不会触发输入法切换，只会保存当前输入法
- 不会出现无限循环

---

## 总结

### Bug 根本原因

1. **状态不一致**：`prev_im` 与实际输入法状态不一致
2. **异步竞态条件**：异步操作期间，输入法状态已改变
3. **焦点事件循环**：`FocusLost` → 切换到 `prev_im`，`FocusGained` → 切换到 `im_select_default`，形成循环

### 修复方案

1. **修改 `set_im_get_im_callback`**：输入法切换后更新 `prev_im` 为目标输入法
2. **修改 `on_focus_gained`**：不切换输入法，只保存当前输入法为 `prev_im`

### 修复效果

- 避免 `FocusGained` 和 `FocusLost` 的循环切换
- 确保 `prev_im` 与实际输入法一致
- 避免基于过期状态的竞态条件
- 不会出现焦点抢占的问题

