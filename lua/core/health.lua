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

local function check_mason()
    vim.health.start("Mason")
    local ok, registry = pcall(require, "mason-registry")
    if not ok then
        vim.health.warn("mason-registry not loaded")
        add("warn", "mason-registry not loaded")
        return
    end

    local settings = require("core.settings")
    local all = {}
    for _, list in ipairs({ settings.lsp_deps, settings.none_ls_deps, settings.dap_deps }) do
        for _, name in ipairs(list) do
            table.insert(all, name)
        end
    end

    local installed, missing = {}, {}
    for _, name in ipairs(all) do
        local pkg_ok, pkg = pcall(registry.get_package, name)
        if pkg_ok and pkg:is_installed() then
            table.insert(installed, name)
        else
            table.insert(missing, name)
        end
    end

    if #installed > 0 then
        vim.health.ok(#installed .. " installed: " .. table.concat(installed, ", "))
    end
    if #missing > 0 then
        vim.health.warn(#missing .. " not installed: " .. table.concat(missing, ", "))
        add("warn", "mason: " .. table.concat(missing, ", ") .. " not installed")
    end
end

local function check_mason_binaries()
    vim.health.start("Mason Binaries")
    local registry_ok, registry = pcall(require, "mason-registry")
    if not registry_ok then
        return
    end

    local settings = require("core.settings")
    local all = {}
    for _, list in ipairs({ settings.lsp_deps, settings.none_ls_deps, settings.dap_deps }) do
        for _, name in ipairs(list) do
            table.insert(all, name)
        end
    end

    local broken = {}
    for _, name in ipairs(all) do
        local pkg_ok, pkg = pcall(registry.get_package, name)
        if pkg_ok and pkg:is_installed() then
            -- Try common binary names
            local bin_names = { name, name .. ".exe" }
            local found = false
            for _, bin in ipairs(bin_names) do
                if vim.fn.executable(bin) == 1 then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(broken, name)
            end
        end
    end

    if #broken > 0 then
        vim.health.warn("installed but binary not in PATH: " .. table.concat(broken, ", "))
        add("warn", "mason binaries broken: " .. table.concat(broken, ", "))
    else
        vim.health.ok("all installed binaries accessible")
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
    local maps = {
        { "n", "<F6>",        "Debug Continue" },
        { "n", "<F8>",        "Debug Breakpoint" },
        { "n", "<leader>gt",  "Go Test" },
        { "n", "<leader>gN",  "Go Debug" },
        { "n", "<leader>ph",  "Lazy" },
        { "n", "<leader>e",   "File browser" },
    }

    local missing = {}
    for _, m in ipairs(maps) do
        local info = vim.fn.maparg(m[2], m[1], false, true)
        if not info or (not info.callback and (not info.rhs or info.rhs == "")) then
            table.insert(missing, m[2] .. " (" .. m[3] .. ")")
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

local function check_lazygit_config()
    vim.health.start("Lazygit Config")
    if has("lazygit") then
        local config_path
        if is_windows then
            config_path = vim.fn.expand("$APPDATA") .. "/lazygit/config.yml"
        else
            config_path = vim.fn.expand("~/.config/lazygit/config.yml")
        end
        if vim.fn.filereadable(config_path) == 1 then
            vim.health.ok("config found: " .. config_path)
        else
            vim.health.warn("config not found at " .. config_path)
            add("warn", "lazygit: no config file")
        end
    else
        vim.health.info("lazygit not installed")
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
    check_mason()
    check_mason_binaries()
    check_lsp()
    check_theme()
    check_keymaps()
    check_plugins()
    check_providers()
    check_shell()
    check_git_config()
    check_lazygit_config()
    check_startup()

    print_summary()
end

return M
