local M = {}

local is_windows = vim.fn.has("win32") == 1

local results = { errors = {}, warnings = {}, infos = {} }

local function has(cmd)
    return vim.fn.executable(cmd) == 1
end

local function add(level, msg)
    if level == "error" then
        table.insert(results.errors, msg)
    elseif level == "warn" then
        table.insert(results.warnings, msg)
    else
        table.insert(results.infos, msg)
    end
end

local function print_summary()
    vim.health.start("Summary")
    if #results.errors == 0 and #results.warnings == 0 then
        vim.health.ok("all checks passed")
        return
    end

    if #results.errors > 0 then
        vim.health.error(#results.errors .. " critical:")
        for _, m in ipairs(results.errors) do
            vim.health.error("  " .. m)
        end
    end
    if #results.warnings > 0 then
        vim.health.warn(#results.warnings .. " warnings:")
        for _, m in ipairs(results.warnings) do
            vim.health.warn("  " .. m)
        end
    end
    if #results.infos > 0 then
        for _, m in ipairs(results.infos) do
            vim.health.info(m)
        end
    end
end

local function check_system()
    vim.health.start("System")
    local required = { "git", "curl", "unzip" }
    local optional = { "go", "cargo", "python3", "python", "node", "lazygit" }

    local missing_req = {}
    for _, cmd in ipairs(required) do
        if not has(cmd) then
            table.insert(missing_req, cmd)
        end
    end
    if #missing_req == 0 then
        vim.health.ok("all required binaries found")
    else
        vim.health.error("missing required: " .. table.concat(missing_req, ", "))
        add("error", "missing required: " .. table.concat(missing_req, ", "))
    end

    local found, missing = {}, {}
    for _, cmd in ipairs(optional) do
        if has(cmd) then
            table.insert(found, cmd)
        else
            table.insert(missing, cmd)
        end
    end
    if #found > 0 then
        vim.health.ok("optional: " .. table.concat(found, ", "))
    end
    if #missing > 0 then
        vim.health.info("not found: " .. table.concat(missing, ", "))
    end
end

local function check_go_env()
    vim.health.start("Go Environment")
    if vim.fn.executable("go") ~= 1 then
        vim.health.info("go not installed, skipping")
        return
    end

    -- GOPATH
    local gopath = vim.fn.system("go env GOPATH 2>&1"):match("^%S+")
    if gopath and gopath ~= "" then
        vim.health.ok("GOPATH: " .. gopath)
    else
        vim.health.warn("GOPATH not set or invalid")
        add("warn", "go: GOPATH not set")
    end

    -- GOROOT
    local goroot = vim.fn.system("go env GOROOT 2>&1"):match("^%S+")
    if goroot and goroot ~= "" then
        vim.health.ok("GOROOT: " .. goroot)
    else
        vim.health.warn("GOROOT not set")
    end

    -- Go version
    local goversion = vim.fn.system("go version 2>&1"):match("go(%S+)")
    if goversion then
        vim.health.ok("version: " .. goversion)
    end

    -- GOPROXY (important for China/behind firewall)
    local goproxy = vim.fn.system("go env GOPROXY 2>&1"):match("^%S+")
    if goproxy and goproxy ~= "https://proxy.golang.org,direct" then
        vim.health.info("GOPROXY: " .. goproxy)
    end
end

-- Внешние бинарники минимального стека (mason нет — всё системное).
-- Совпадает с гардами в completion/lsp.lua, lang/lint.lua, tool/fzf.lua.
local function check_tools()
    vim.health.start("External Tools")
    local lsp_bins = { gopls = "gopls", lua_ls = "lua-language-server", bashls = "bash-language-server" }
    local needed, missing = {}, {}
    for _, name in ipairs(require("core.settings").lsp_deps) do
        local bin = lsp_bins[name] or name
        if has(bin) then
            table.insert(needed, name .. " (" .. bin .. ")")
        else
            table.insert(missing, name .. " (" .. bin .. ")")
        end
    end
    if #missing == 0 then
        vim.health.ok("LSP servers: " .. table.concat(needed, ", "))
    else
        vim.health.warn("LSP servers missing (skipped at startup): " .. table.concat(missing, ", "))
        add("warn", "missing LSP: " .. table.concat(missing, ", "))
    end

    if has("golangci-lint") then
        vim.health.ok("linter: golangci-lint")
    else
        vim.health.warn("golangci-lint missing (go lint disabled)")
        add("warn", "missing linter: golangci-lint")
    end

    if has("fzf") then
        vim.health.ok("picker: fzf")
    else
        vim.health.error("fzf missing — fzf-lua picker is dead (brew install fzf)")
        add("error", "missing picker: fzf")
    end
    if has("rg") then
        vim.health.ok("grep: rg")
    else
        vim.health.warn("rg missing — live grep will fail")
        add("warn", "missing grep: rg")
    end
    if not has("fd") then
        vim.health.info("fd not found (files picker falls back to slower find)")
    end

    -- Компилятор нужен один раз: сборка treesitter-парсеров и LuaSnip jsregexp.
    -- Без него нет подсветки!
    if has("cc") or has("gcc") or has("cl") or has("clang") then
        vim.health.ok("C compiler present (treesitter/LuaSnip build)")
    else
        vim.health.error("no C compiler (cc/gcc/clang/cl) — treesitter parsers cannot build")
        add("error", "no C compiler for treesitter/LuaSnip")
    end
    if not has("make") and not is_windows then
        vim.health.warn("make missing (LuaSnip jsregexp build needs it)")
        add("warn", "make missing")
    end
end

local function check_lsp()
    vim.health.start("LSP")
    local clients = vim.lsp.get_clients()
    if #clients == 0 then
        vim.health.info("no active clients (open a file to start)")
        return
    end
    for _, c in ipairs(clients) do
        if c.is_stopped() then
            vim.health.warn(c.name .. " — stopped")
            add("warn", "lsp: " .. c.name .. " stopped")
        else
            vim.health.ok(c.name .. " — running")
        end
    end
end

local function check_theme()
    vim.health.start("Theme")
    local expected = require("core.settings").colorscheme
    local current = vim.g.colors_name or ""

    if current == expected then
        vim.health.ok("colorscheme: " .. current)
    else
        vim.health.warn("expected '" .. expected .. "', got '" .. current .. "'")
        add("warn", "theme: expected '" .. expected .. "', got '" .. current .. "'")
    end

    local groups = { "Normal", "Comment", "Keyword", "String", "Function", "Type",
        "DiagnosticError", "GitSignsAdd", "DapBreakpoint", "DapStopped" }
    local missing = {}
    for _, g in ipairs(groups) do
        local hl = vim.api.nvim_get_hl(0, { name = g })
        if not hl or next(hl) == nil then
            table.insert(missing, g)
        end
    end
    if #missing == 0 then
        vim.health.ok(#groups .. " highlight groups OK")
    else
        vim.health.warn("missing highlights: " .. table.concat(missing, ", "))
        add("warn", "highlights missing: " .. table.concat(missing, ", "))
    end
end

local function check_keymaps()
    vim.health.start("Keymaps")
    -- Без дублей: gd/gr/K буферные (LspAttach) — из health:// их не видно,
    -- поэтому чекаем только глобальные; LSP-мапы проверяются на живом буфере.
    local maps = {
        { "n", "<leader>ff",  "Find files" },
        { "n", "<leader>fp",  "Live grep" },
        { "n", "<leader>e",   "File browser" },
        { "n", "<leader>ph",  "Lazy" },
        { "n", "<leader>q",   "Quickfix toggle" },
    }

    local missing = {}
    -- LSP-клавиши буферные: ищем по всем listed-буферам через API,
    -- т.к. maparg смотрит только текущий буфер (а чек бежит из health://).
    local buf_maps = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.fn.buflisted(b) == 1 then
            for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
                buf_maps[m.lhs] = true
            end
        end
    end
    for _, m in ipairs(maps) do
        local info = vim.fn.maparg(m[2], m[1], false, true)
        local ok = info and (info.callback or (info.rhs and info.rhs ~= ""))
        if not ok then
            -- mapleader в выдаче API раскрыт в <Space>? сверяем оба вида
            local want = m[2]:gsub("<leader>", vim.g.mapleader or " ")
            if not buf_maps[m[2]] and not buf_maps[want] then
                table.insert(missing, m[2] .. " (" .. m[3] .. ")")
            end
        end
    end
    if #missing == 0 then
        vim.health.ok(#maps .. " keymaps OK")
    else
        vim.health.warn("not mapped: " .. table.concat(missing, ", "))
        add("warn", "keymaps missing: " .. table.concat(missing, ", "))
    end
end

local function check_plugins()
    vim.health.start("Plugins")
    local lazy_ok, lazy = pcall(require, "lazy")
    if not lazy_ok then
        vim.health.error("lazy.nvim not available")
        add("error", "lazy.nvim not available")
        return
    end

    local loaded, errs = 0, {}
    for _, p in ipairs(lazy.plugins()) do
        if p._.loaded then
            loaded = loaded + 1
        end
        if p._.errors and #p._.errors > 0 then
            table.insert(errs, p.name)
        end
    end

    if #errs == 0 then
        vim.health.ok(loaded .. " plugins loaded, no errors")
    else
        vim.health.warn(loaded .. " loaded, errors in: " .. table.concat(errs, ", "))
        add("warn", "plugin errors: " .. table.concat(errs, ", "))
    end
end

local function check_providers()
    vim.health.start("Providers")

    -- Python
    local python_cmd = has("python3") and "python3" or (has("python") and "python" or nil)
    if python_cmd then
        local redirect = is_windows and "2>NUL" or "2>&1"
        local out = vim.fn.system(python_cmd .. " -c 'import pynvim' " .. redirect)
        if not out:match("No module") and not out:match("ModuleNotFoundError") then
            vim.health.ok(python_cmd .. " + pynvim")
        else
            vim.health.warn(python_cmd .. " found but pynvim missing")
            add("warn", "python: pynvim not installed")
        end
    else
        vim.health.info("python not found (optional)")
    end

    -- Node
    if has("node") then
        vim.health.ok("node.js")
    else
        vim.health.info("node.js not found (optional)")
    end

    -- Clipboard
    if vim.fn.has("clipboard") == 1 then
        vim.health.ok("clipboard")
    else
        vim.health.warn("clipboard not available")
        add("warn", "clipboard not available")
    end
end

local function check_shell()
    vim.health.start("Shell")
    local is_windows = vim.fn.has("win32") == 1

    if is_windows then
        local shell = vim.o.shell
        if shell:match("powershell") or shell:match("pwsh") then
            vim.health.ok("shell: " .. shell)
        else
            vim.health.warn("shell: " .. shell .. " (powershell recommended)")
            add("warn", "shell: not using powershell")
        end
    else
        vim.health.ok("shell: " .. vim.o.shell)
    end
end

local function check_git_config()
    if not require("core.settings").sync_git_colors then
        return
    end
    vim.health.start("Git Config")
    if vim.fn.executable("git") ~= 1 then
        vim.health.info("git not installed, skipping")
        return
    end

    local redirect = is_windows and "2>NUL" or "2>/dev/null"
    local diff_old = vim.fn.system("git config --global color.diff.old " .. redirect):match("^%S+")
    local diff_new = vim.fn.system("git config --global color.diff.new " .. redirect):match("^%S+")

    if diff_old and diff_new then
        vim.health.ok("diff colors: " .. diff_new .. " / " .. diff_old)
    else
        vim.health.warn("git diff colors not set (lazygit will use defaults)")
        add("warn", "git: diff colors not configured")
    end
end


local function check_startup()
    vim.health.start("Startup")
    local t = vim.g.start_time
    if t then
        local ms = vim.fn.reltimefloat(vim.fn.reltime(t)) * 1000
        if ms > 300 then
            vim.health.error(string.format("%dms (very slow)", ms))
            add("error", "startup: " .. string.format("%dms", ms))
        elseif ms > 100 then
            vim.health.warn(string.format("%dms (slow)", ms))
            add("warn", "startup: " .. string.format("%dms", ms))
        else
            vim.health.ok(string.format("%dms", ms))
        end
    end
end

M.check = function()
    results = { errors = {}, warnings = {}, infos = {} }
    vim.health.start("=== MyConfig ===")

    check_system()
    check_go_env()
    check_tools()
    check_lsp()
    check_theme()
    check_keymaps()
    check_plugins()
    check_providers()
    check_shell()
    check_git_config()
    check_startup()

    print_summary()
end

return M
