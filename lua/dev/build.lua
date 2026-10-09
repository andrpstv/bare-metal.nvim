-- dev.build — `go build` / `go run` текущего пакета с понятным фидбэком.
--
-- Почему свой, а не :GoBuild/:GoRun (go.nvim): те без аргументов выполняют
-- голый `go build`/`go run` в CWD (а CWD у нас — корень проекта из-за
-- project-cd), поэтому rb/rr на вложенном пакете падали с "no Go files"
-- вместо сборки пакета текущего файла. Здесь: пакет = каталог файла,
-- запуск через vim.system, ошибки компиляции — в quickfix (тот же формат
-- строк, что у dev.test), успех/провал — в notify. Команды :GoBuild/:GoRun
-- остаются доступны напрямую.
local M = {}

--- Каталог пакета для буфера: каталог файла (go сам резолвит модуль вверх,
--- включая nested modules и go.work — никакой магии тут не нужно).
---@param bufnr integer?
---@return string? dir, string? err
function M.pkg_dir(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local f = vim.api.nvim_buf_get_name(bufnr)
	if f == "" then
		return nil, "buffer has no file"
	end
	return vim.fn.fnamemodify(f, ":p:h"), nil
end

--- Корень модуля для diagnostics (переиспользуем dev.gomod).
local function module_root(bufnr)
	local ok, gomod = pcall(require, "dev.gomod")
	if ok and gomod and gomod.mod_root then
		local f = vim.api.nvim_buf_get_name(bufnr)
		return gomod.mod_root(f)
	end
	return nil
end

-- Строка вида "foo.go:42: message" (go build/run) → qf item. Тот же формат,
-- что парсит dev.test (там локально); дублируем однострочник осознанно,
-- чтобы не тащить зависимость между движками.
local function qf_items(output, dir)
	local items = {}
	for _, line in ipairs(vim.split(output or "", "\n", { plain = true })) do
		local f, l, msg = line:match("^%s*([%w_%.%-/\\]+%.go):(%d+):%s*(.-)%s*$")
		if f and msg and msg ~= "" then
			if not f:match("^/") and not f:match("^%a:") then
				f = dir .. "/" .. f
			end
			items[#items + 1] = { filename = f, lnum = tonumber(l), col = 1, text = msg }
		end
	end
	return items
end

---@param op "build"|"run"
---@param extra string[]? доп. флаги (после subcommand)
local function execute(op, extra)
	if vim.fn.executable("go") ~= 1 then
		vim.notify("[go] 'go' not in PATH", vim.log.levels.ERROR, { title = "go" })
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.bo[bufnr].filetype ~= "go" then
		vim.notify("[go] Go buffers only", vim.log.levels.WARN, { title = "go" })
		return
	end
	local dir, err = M.pkg_dir(bufnr)
	if not dir then
		vim.notify("[go] " .. err, vim.log.levels.WARN, { title = "go" })
		return
	end
	if not module_root(bufnr) then
		vim.notify("[go] no go.mod above current file — building anyway", vim.log.levels.WARN, { title = "go" })
	end
	local argv = { "go", op == "build" and "build" or "run", "." }
	if extra then
		vim.list_extend(argv, extra)
	end
	vim.notify("[go] " .. table.concat(argv, " ") .. "  (" .. dir .. ")", vim.log.levels.INFO, { title = "go" })
	vim.system(argv, { text = true, cwd = dir }, function(obj)
		vim.schedule(function()
			local code = obj and obj.code or 1
			local out = ((obj and obj.stdout) or "") .. "\n" .. ((obj and obj.stderr) or "")
			if code == 0 then
				vim.notify("[go] " .. op .. " clean", vim.log.levels.INFO, { title = "go" })
				pcall(vim.cmd, "cclose")
				return
			end
			local items = qf_items(out, dir)
			if #items > 0 then
				vim.fn.setqflist({}, " ", { title = "go " .. op .. ": " .. dir, items = items })
				vim.cmd("copen")
			end
			local first = out:gsub("%s+$", ""):match("[^\n]*$") or ""
			vim.notify("[go] " .. op .. " FAILED (code " .. code .. ")" .. (#items > 0 and "" or ": " .. first:sub(1, 200)), vim.log.levels.ERROR, { title = "go" })
		end)
	end)
end

--- Собрать пакет текущего файла (`go build .` в его каталоге).
function M.build()
	execute("build")
end

--- Запустить пакет текущего файла (`go run .` в его каталоге).
function M.run()
	execute("run")
end

return M
