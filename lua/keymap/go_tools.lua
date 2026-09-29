-- Go-инструменты с видимым статусом: `go get` недостающих импортов во флоате.
local map = vim.keymap.set

local log_buf, log_win = nil, nil

local function log_close()
	if log_win and vim.api.nvim_win_is_valid(log_win) then
		pcall(vim.api.nvim_win_close, log_win, true)
	end
	log_win, log_buf = nil, nil
end

local function log_append(line)
	if not (log_buf and vim.api.nvim_buf_is_valid(log_buf)) then
		return
	end
	pcall(vim.api.nvim_buf_set_lines, log_buf, -1, -1, false, vim.split(line, "\n", { plain = true }))
	if log_win and vim.api.nvim_win_is_valid(log_win) then
		pcall(vim.api.nvim_win_set_cursor, log_win, { vim.api.nvim_buf_line_count(log_buf), 0 })
	end
end

local function log_open(title)
	log_close()
	log_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[log_buf].filetype = "distro-task-log"
	vim.bo[log_buf].modifiable = true
	local width = math.min(100, math.floor(vim.o.columns * 0.6))
	local height = math.min(16, math.floor(vim.o.lines * 0.4))
	log_win = vim.api.nvim_open_win(log_buf, false, {
		relative = "editor",
		width = width,
		height = height,
		col = vim.o.columns - width - 2,
		row = 2,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
	})
	vim.api.nvim_buf_set_keymap(log_buf, "n", "q", "", {
		noremap = true,
		silent = true,
		callback = log_close,
		desc = "close task log",
	})
	vim.api.nvim_buf_set_keymap(log_buf, "n", "<Esc>", "", {
		noremap = true,
		silent = true,
		callback = log_close,
		desc = "close task log",
	})
	return log_buf
end

---Собрать недостающие импорты из диагностики (BrokenImport / no required module).
---@param bufnr integer
---@return string[] module paths
local function missing_imports(bufnr)
	local found, seen = {}, {}
	for _, d in ipairs(vim.diagnostic.get(bufnr)) do
		local msg = d.message or ""
		local path = msg:match("could not import ([%w%./%-%_~]+)")
			or msg:match('no required module provides.-"([^"]+)"')
			or msg:match("cannot find package \"([^\"]+)\"")
		if path and not seen[path] then
			seen[path] = true
			found[#found + 1] = path
		end
	end
	return found
end

_G._go_get_missing = function()
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.bo[bufnr].filetype ~= "go" then
		vim.notify("[go] go-get works in Go files only", vim.log.levels.WARN, { title = "go" })
		return
	end
	local fname = vim.api.nvim_buf_get_name(bufnr)
	local moddir = vim.fs.root(fname, { "go.mod" })
	if not moddir then
		vim.notify("[go] no go.mod above this file", vim.log.levels.WARN, { title = "go" })
		return
	end
	local paths = missing_imports(bufnr)
	if #paths == 0 then
		vim.notify("[go] no missing imports in diagnostics", vim.log.levels.INFO, { title = "go" })
		return
	end
	if vim.fn.executable("go") ~= 1 then
		vim.notify("[go] 'go' not in $PATH", vim.log.levels.ERROR, { title = "go" })
		return
	end
	local choice = vim.fn.confirm("go get:\n  " .. table.concat(paths, "\n  "), "&Yes\n&No", 2)
	if choice ~= 1 then
		return
	end
	log_open("go get")
	local i = 0
	local function step()
		i = i + 1
		if i > #paths then
			log_append("done — save the buffer to refresh gopls (<leader>lr if stuck)")
			vim.notify("[go] go get done: " .. #paths .. " module(s)", vim.log.levels.INFO, { title = "go" })
			return
		end
		local p = paths[i]
		log_append("$ go get " .. p)
		vim.system({ "go", "get", p }, { text = true, cwd = moddir }, function(res)
			vim.schedule(function()
				local out = vim.trim((res.stdout or "") .. (res.stderr or ""))
				if res.code == 0 then
					log_append("  ok: " .. p)
				else
					log_append("  FAIL(" .. res.code .. "): " .. p .. "\n  " .. out:sub(1, 300):gsub("\n", " | "))
					vim.notify("[go] go get FAILED: " .. p, vim.log.levels.ERROR, { title = "go" })
					return
				end
				step()
			end)
		end)
	end
	step()
end

map("n", "<leader>gg", function()
	_G._go_get_missing()
end, { noremap = true, silent = true, desc = "go: get missing imports (float log)" })
