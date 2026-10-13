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

-- Строка вида "foo.go:42[:7]: message" (go build/run/vet, golangci-lint) → qf item.
-- Тот же формат, что парсит dev.test (там локально); дублируем осознанно,
-- чтобы не тащить зависимость между движками.
local function qf_items(output, dir)
	local items = {}
	for _, line in ipairs(vim.split(output or "", "\n", { plain = true })) do
		local f, l, c, msg = line:match("^%s*([%w_%.%-/\\]+%.go):(%d+):(%d+):%s*(.-)%s*$")
		if not f then
			f, l, msg = line:match("^%s*([%w_%.%-/\\]+%.go):(%d+):%s*(.-)%s*$")
		end
		if f and msg and msg ~= "" then
			if not f:match("^/") and not f:match("^%a:") then
				f = dir .. "/" .. f
			end
			items[#items + 1] = { filename = f, lnum = tonumber(l), col = tonumber(c) or 1, text = msg }
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
	require("dev.bear").busy("go")
	vim.system(argv, { text = true, cwd = dir }, function(obj)
		vim.schedule(function()
			local code = obj and obj.code or 1
			require("dev.bear").done("go", code == 0)
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

--- Проверить весь модуль: `go build ./...`, затем `go vet ./...` и, если стоит,
--- `golangci-lint run ./...` → один quickfix. Нужно после правок агента: LSP
--- видит загруженные пакеты, а агент мог тронуть любые. Сломанная сборка
--- обрывает цепочку — vet/lint повторили бы те же ошибки.
function M.check()
	if vim.fn.executable("go") ~= 1 then
		vim.notify("[go] 'go' not in PATH", vim.log.levels.ERROR, { title = "go" })
		return
	end
	local start = vim.api.nvim_buf_get_name(0)
	if start == "" or vim.bo.buftype ~= "" then
		start = require("dev.project").root() -- из quickfix/окна агента: от проекта
	end
	local root = require("dev.gomod").mod_root(start)
	if not root then
		vim.notify("[go] no go.mod above " .. start, vim.log.levels.WARN, { title = "go" })
		return
	end
	-- -o null: один main-пакет иначе оставит бинарник в корне проекта (виден в git и в ревью).
	local steps = { { "go", "build", "-o", require("distro.install").null_dev(), "./..." }, { "go", "vet", "./..." } }
	if vim.fn.executable("golangci-lint") == 1 then
		steps[#steps + 1] = { "golangci-lint", "run", "./..." }
	end
	vim.notify("[go] checking module " .. root .. " (" .. #steps .. " steps)", vim.log.levels.INFO, { title = "go" })
	local items, failed = {}, {}
	require("dev.bear").busy("go")
	local function step(i)
		local argv = steps[i]
		if not argv then
			require("dev.bear").done("go", #failed == 0)
			vim.fn.setqflist({}, " ", { title = "go check: " .. root, items = items })
			if #items > 0 then
				vim.cmd("copen")
			else
				pcall(vim.cmd, "cclose")
			end
			if #failed == 0 then
				vim.notify("[go] check clean (" .. #steps .. " steps)", vim.log.levels.INFO, { title = "go" })
			else
				vim.notify("[go] check: " .. #items .. " issue(s) — " .. table.concat(failed, "; "), vim.log.levels.WARN, { title = "go" })
			end
			return
		end
		local label = argv[1] == "go" and argv[2] or "lint"
		vim.system(argv, { text = true, cwd = root }, function(obj)
			vim.schedule(function()
				local out = ((obj and obj.stdout) or "") .. "\n" .. ((obj and obj.stderr) or "")
				local found = qf_items(out, root)
				for _, it in ipairs(found) do
					it.text = "[" .. label .. "] " .. it.text
				end
				vim.list_extend(items, found)
				if (obj and obj.code or 1) ~= 0 then
					local last = #found == 0 and (": " .. (out:gsub("%s+$", ""):match("[^\n]*$") or ""):sub(1, 160)) or ""
					failed[#failed + 1] = label .. " failed" .. last
					if i == 1 then
						return step(#steps + 1)
					end
				end
				step(i + 1)
			end)
		end)
	end
	step(1)
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
