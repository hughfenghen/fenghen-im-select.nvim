local M = {}

local function rstrip(str, chars)
    if #str > 0 and #chars > 0 then
        local i = #str
        while i >= 1 do
            if chars:find(str:sub(i, i), 1, true) then
                i = i - 1
            else
                break
            end
        end
        if i == 0 then
            i = 1
        end
        return str:sub(1, i)
    else
        return str
    end
end

M.rstrip = rstrip

local ImSetJob = {}
ImSetJob.__index = ImSetJob

function ImSetJob.new(cmd)
    local self = setmetatable({}, ImSetJob)
    self.cmd = cmd
    self.handle = nil
    self:run()
    return self
end

function ImSetJob:run()
    local program = self.cmd[1]
    local args = {}
    for i = 2, #self.cmd do
        table.insert(args, self.cmd[i])
    end

    self.handle = vim.loop.spawn(
        program,
        {
            args = args,
            detach = true,
        },
        vim.schedule_wrap(function(code, signal)
            if self.handle and not self.handle:is_closing() then
                self.handle:close()
            end
        end)
    )

    if not self.handle then
        vim.api.nvim_err_writeln("[im-select]: Failed to spawn process for " .. program)
    end
end

function ImSetJob:wait()
    vim.wait(5000, function()
        return not self.handle or self.handle:is_closing()
    end, 200)
end

M.ImSetJob = ImSetJob

local ImGetJob = {}
ImGetJob.__index = ImGetJob

function ImGetJob.new(cmd, callback, set_prev_im)
    local self = setmetatable({}, ImGetJob)
    self.cmd = cmd
    self.callback = callback
    self.set_prev_im = set_prev_im
    self.stdout = {}
    self.stderr = {}
    self.handle = nil
    self:run()
    return self
end

function ImGetJob:run()
    local program = self.cmd[1]
    local args = {}
    for i = 2, #self.cmd do
        table.insert(args, self.cmd[i])
    end

    self.stdout = {}
    self.stderr = {}

    local stdout_pipe = vim.loop.new_pipe(false)
    local stderr_pipe = vim.loop.new_pipe(false)

    self.handle = vim.loop.spawn(
        program,
        {
            args = args,
            stdio = { nil, stdout_pipe, stderr_pipe },
        },
        vim.schedule_wrap(function(code, signal)
            local stdout_str = table.concat(self.stdout, "")
            local stderr_str = table.concat(self.stderr, "")

            if self.callback then
                local result = self.callback(code, rstrip(stdout_str, " \r\n"), rstrip(stderr_str, " \r\n"))

                if self.set_prev_im then
                    vim.g.im_select_prev_im = result
                end
            end

            if self.handle then
                self.handle:close()
            end
            stdout_pipe:close()
            stderr_pipe:close()
        end)
    )

    if not self.handle then
        vim.api.nvim_err_writeln("[im-select]: Failed to spawn process for " .. program)
        return
    end

    vim.loop.read_start(stdout_pipe, function(err, data)
        if not err then
            table.insert(self.stdout, data or "")
        end
    end)

    vim.loop.read_start(stderr_pipe, function(err, data)
        if not err then
            table.insert(self.stderr, data or "")
        end
    end)
end

function ImGetJob:wait()
    vim.wait(5000, function()
        return not self.handle or self.handle:is_closing()
    end, 200)
end

M.ImGetJob = ImGetJob

return M
