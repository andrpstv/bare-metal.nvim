local M = {}

---Setup and enable a language server in one call.
---@param server string @Name of the language server
---@param config? vim.lsp.Config @Optional config to apply
function M.register_server(server, config)
	vim.validate("server", server, "string", false)
	vim.validate("config", config, "table", true)

	if config then
		local ok_cfg, err_cfg = pcall(vim.lsp.config, server, config)
		if not ok_cfg then
			vim.notify("register_server " .. server .. ": " .. tostring(err_cfg):sub(1, 120), vim.log.levels.WARN, { title = "[lsp]" })
			return
		end
	end
	local ok_en, err_en = pcall(vim.lsp.enable, server)
	if not ok_en then
		vim.notify("register_server enable " .. server .. ": " .. tostring(err_en):sub(1, 120), vim.log.levels.WARN, { title = "[lsp]" })
	end
end

---True if the buffer is a real file. Plugin buffers like diffview://,
---fugitive:// or oil:// carry a non-file URI scheme that servers such as
---gopls reject with JSON RPC -32700 — keep all LSP extras away from them.
---@param bufnr integer
---@return boolean
function M.is_file_buffer(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return true
	end
	local scheme = name:match("^([%w%.%+%-]+)://")
	return scheme == nil or scheme == "file"
end

---True if the file lives in the Go module cache or toolchain (read-only libs).
---gopls attaches there for goto-def/hover but has no package metadata.
---@param file string
---@return boolean
function M.is_go_lib(file)
	-- Сепаратор-агностично: bufname бывает и C:/Program Files/Go/... (прямые),
	-- и C:\Users\...\go\pkg\mod\... (обратные). Классы [\\/] вместо двух веток.
	file = file or ""
	return file:match("/go/pkg/mod/")
		or file:match("/opt/homebrew/Cellar/go/")
		or file:match("/opt/homebrew/opt/go/")
		or file:match("/usr/local/go/")
		or file:match("/usr/lib/go")
		or file:match("[\\/]go[\\/]pkg[\\/]mod[\\/]")
		or file:match("Program Files[\\/]Go[\\/]")
end

---True if gopls is usable: in PATH, or a standard `go install` landing
---spot. go.nvim appends GOPATH/bin to PATH lazily on its own load, so a
---FileType-time executable() check alone false-negatives on the most
---common install layout (~/go/bin/gopls, system PATH clean). No spawns:
---only env + filereadable, safe on every FileType.
---Windows: бинарь — gopls.exe; GOPATH бывает списком через ';' — берём первый.
---@return boolean
function M.gopls_found()
	if vim.fn.executable("gopls") == 1 then
		return true
	end
	local dirs = {}
	if vim.env.GOBIN and vim.env.GOBIN ~= "" then
		dirs[#dirs + 1] = vim.env.GOBIN
	end
	if vim.env.GOPATH and vim.env.GOPATH ~= "" then
		-- GOPATH бывает списком (';' на Windows, ':' на unix), bin — у первого.
		-- Букву диска ('C:') не режем: сначала ';'-хвост, ':'-хвост только
		-- если спереди не буква диска.
		local first = vim.env.GOPATH:match("^([^;]+)") or vim.env.GOPATH
		if not first:match("^[A-Za-z]:") then
			first = first:match("^([^:]+)") or first
		end
		dirs[#dirs + 1] = first .. "/bin"
	end
	dirs[#dirs + 1] = vim.fn.expand("~/go/bin")
	for _, d in ipairs(dirs) do
		if vim.fn.executable(d .. "/gopls") == 1 or vim.fn.executable(d .. "/gopls.exe") == 1 then
			return true
		end
	end
	return false
end

--- Function to recursively merge src into dst
--- Unlike vim.tbl_deep_extend(), this function extends if the original value is a list
---@paramm dst table @Table which will be modified and appended to
---@paramm src table @Table from which values will be inserted
---@return table @Modified table
local function tbl_recursive_merge(dst, src)
	for key, value in pairs(src) do
		if type(dst[key]) == "table" and type(value) == "function" then
			dst[key] = value(dst[key])
		elseif type(dst[key]) == "table" and vim.islist(dst[key]) then
			vim.list_extend(dst[key], value)
		elseif type(dst[key]) == "table" and type(value) == "table" and not vim.islist(dst[key]) then
			tbl_recursive_merge(dst[key], value)
		else
			dst[key] = value
		end
	end
	return dst
end

-- Function to extend existing core configs (settings, events, etc.)
---@param config table @The default config to be merged with
---@param user_config string @The module name used to require user config
---@return table @Extended config
function M.extend_config(config, user_config)
	local ok, extras = pcall(require, user_config)
	if ok and type(extras) == "table" then
		config = tbl_recursive_merge(config, extras)
	end
	return config
end

---@param plugin_name string @Module name of the plugin (used to setup itself)
---@param opts nil|table @The default config to be merged with
---@param vim_plugin? boolean @If this plugin is written in vimscript or not
---@param setup_callback? function @Add new callback if the plugin needs unusual setup function
function M.load_plugin(plugin_name, opts, vim_plugin, setup_callback)
	vim_plugin = vim_plugin or false

	-- Get the file name of the default config
	local fname = debug.getinfo(2, "S").source:match("[^@/\\]*.lua$")
	local ok, user_config = pcall(require, "user.configs." .. fname:sub(0, #fname - 4))
	if ok and vim_plugin then
		if user_config == false then
			-- Return early if the user explicitly requires disabling plugin setup
			return
		elseif type(user_config) == "function" then
			-- OK, setup as instructed by the user
			user_config()
		else
			vim.notify(
				string.format(
					"<%s> is not a typical Lua plugin, please return a function with\nthe corresponding options defined instead (usually via `vim.g.*`)",
					plugin_name
				),
				vim.log.levels.ERROR,
				{ title = "[utils] Runtime Error (User Config)" }
			)
		end
	elseif not vim_plugin then
		if user_config == false then
			-- Return early if the user explicitly requires disabling plugin setup
			return
		else
			if not setup_callback then
				local ok_mod, mod_or_err = pcall(require, plugin_name)
				if not ok_mod then
					vim.notify(
						"load_plugin <" .. plugin_name .. "> skipped: " .. tostring(mod_or_err):sub(1, 160),
						vim.log.levels.WARN,
						{ title = "[utils] Plugin" }
					)
					return
				end
				setup_callback = mod_or_err.setup
			end
			-- NOTE: setup бывает таблицей с __call (nvim-cmp) — проверяем вызываемость.
			local mt = type(setup_callback) == "table" and getmetatable(setup_callback) or nil
			if type(setup_callback) ~= "function" and not (mt and mt.__call) then
				vim.notify("load_plugin <" .. plugin_name .. "> has no setup()", vim.log.levels.WARN, { title = "[utils] Plugin" })
				return
			end
			-- User config exists?
			if ok then
				-- Extend base config if the returned user config is a table
				if type(user_config) == "table" then
					opts = tbl_recursive_merge(opts, user_config)
					setup_callback(opts)
				-- Replace base config if the returned user config is a function
				elseif type(user_config) == "function" then
					local user_opts = user_config(opts)
					if type(user_opts) == "table" then
						setup_callback(user_opts)
					end
				else
					vim.notify(
						string.format(
							[[
Please return a `table` if you want to override some of the default options OR a
`function` returning a `table` if you want to replace the default options completely.

We received a `%s` for plugin <%s>.]],
							type(user_config),
							plugin_name
						),
						vim.log.levels.ERROR,
						{ title = "[utils] Runtime Error (User Config)" }
					)
				end
			else
				-- Nothing provided... Fallback as default setup of the plugin
				setup_callback(opts)
			end
		end
	end
end

return M
