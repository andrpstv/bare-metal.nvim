-- dev.replace — project-wide search & replace, Vim-native.
--
-- Почему свой, а не grug-far.nvim: цепочка и так есть (rg → quickfix),
-- не хватало только preview + confirm + apply. 120 строк вместо плагина
-- со своей UI-парадигмой; результат — обычый quickfix, дальше работают
-- :cnext/:cdo/макросы и все привычные инструменты.
--
-- Флоу: <leader>sr → паттерн (по умолч. слово под курсором) → rg --vimgrep
-- → quickfix + copen (это и есть preview) → confirm: All / This file /
-- Cancel → применение через скрытые буферы (%s с тем же паттерном) → отчёт.
-- Visual <leader>sr: паттерн из выделения (буквально, \V).

local M = {}

local function proj_root()
	local ok, proj = pcall(require, "dev.project")
	if ok and proj.root then
		return proj.root()
	end
	return vim.fn.getcwd(-1, -1)
end

local function has_rg()
	if vim.fn.executable("rg") ~= 1 then
		vim.notify(
			"[replace] ripgrep not found — project replace needs rg (:DistroTools to install)",
			vim.log.levels.ERROR,
			{ title = "replace" }
		)
		return false
	end
	return true
end

--- rg --vimgrep → quickfix items. Возвращает items + сырые строки.
---@return table|nil items, string|nil err
local function rg_search(pattern, root)
	local obj = vim.system({ "rg", "--vimgrep", "--no-heading", "--", pattern, root }, { text = true }):wait(30000)
	if not obj then
		return nil, "rg produced no result object"
	end
	if obj.code == 1 then
		return {}, nil -- совпадений нет — не ошибка
	end
	if obj.code ~= 0 then
		return nil, "rg failed (" .. tostring(obj.code) .. "): " .. tostring(obj.stderr or ""):sub(1, 200)
	end
	local items = {}
	for _, line in ipairs(vim.split(obj.stdout or "", "\n", { plain = true })) do
		local f, l, c, text = line:match("^(.-):(%d+):(%d+):(.*)$")
		if f then
			items[#items + 1] = { filename = f, lnum = tonumber(l), col = tonumber(c), text = text }
		end
	end
	return items, nil
end

--- Применить замену к файлам из qf-списка (только выбранные файлы).
---@return integer changed_files, integer changed_total
local function apply(pattern, repl, items, only_file)
	local byfile, order = {}, {}
	for _, it in ipairs(items) do
		local f = it.filename
		if not only_file or f == only_file then
			if not byfile[f] then
				byfile[f] = 0
				order[#order + 1] = f
			end
			byfile[f] = byfile[f] + 1
		end
	end
	if #order == 0 then
		return 0, 0
	end
	-- Паттерн пользователя — vim-regex; экранируем только разделитель.
	local pat = pattern:gsub("/", "\\/")
	local rep = repl:gsub("/", "\\/"):gsub("\n", "\\r")
	local files, total = 0, 0
	for _, f in ipairs(order) do
		local buf = vim.fn.bufadd(f)
		vim.fn.bufload(buf)
		if not vim.api.nvim_buf_is_valid(buf) then
			vim.notify("[replace] cannot load " .. f, vim.log.levels.WARN, { title = "replace" })
		else
			local n = 0
			vim.api.nvim_buf_call(buf, function()
				-- silent! e: несовпадение после правок конкурента — не смерть.
				n = vim.cmd("silent! %s/" .. pat .. "/" .. rep .. "/ge") or 0
			end)
			-- vim.cmd возвращает nil; считаем по факту записи: сравниваем
			-- changedtick? Проще и честнее: пишем только если буфер грязный.
			if vim.bo[buf].modified then
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("silent! update")
				end)
				files = files + 1
				total = total + (byfile[f] or 0)
			end
		end
		-- Не копим скрытые буферы: выгружаем неактивные.
		local cur = vim.api.nvim_get_current_buf()
		if buf ~= cur then
			for _, w in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_get_buf(w) == buf then
					goto keep
				end
			end
			pcall(vim.api.nvim_buf_delete, buf, { unload = true })
			::keep::
		end
	end
	return files, total
end

--- Точка входа: паттерн (+опц. замена) → поиск → qf → confirm → apply.
---@param init_pattern string?
---@param init_repl string?
function M.project(init_pattern, init_repl)
	if not has_rg() then
		return
	end
	vim.ui.input({ prompt = "Replace in project: ", default = init_pattern or vim.fn.expand("<cword>") }, function(pattern)
		if not pattern or pattern == "" then
			return
		end
		vim.ui.input({ prompt = "With: ", default = init_repl or "" }, function(repl)
			if repl == nil then
				return
			end
			local root = proj_root()
			local items, err = rg_search(pattern, root)
			if err then
				vim.notify("[replace] " .. err, vim.log.levels.ERROR, { title = "replace" })
				return
			end
			if #items == 0 then
				vim.notify("[replace] no matches for /" .. pattern .. "/", vim.log.levels.INFO, { title = "replace" })
				return
			end
			local files = {}
			for _, it in ipairs(items) do
				files[it.filename] = true
			end
			local nfiles = 0
			for _ in pairs(files) do
				nfiles = nfiles + 1
			end
			vim.fn.setqflist({}, " ", { title = "replace: " .. pattern, items = items })
			-- Файл для "This file" фиксируем ДО copen: после него текущий
			-- буфер — quickfix (имени нет) и выбор молча бил бы по всем файлам.
			local cur_file = vim.api.nvim_buf_get_name(0)
			if cur_file == "" then
				cur_file = nil
			end
			vim.cmd("copen")
			local choice = vim.fn.confirm(
				string.format("%d matches in %d files. Replace with '%s'?", #items, nfiles, repl),
				"&All\n&This file\n&Cancel",
				3
			)
			if choice == 3 or choice == 0 then
				return
			end
			local only = nil
			if choice == 2 then
				only = cur_file
			end
			local cf, ct = apply(pattern, repl, items, only)
			-- Обновить qf: после замены список протух — перезапускаем поиск.
			local fresh = rg_search(pattern, root)
			if fresh then
				vim.fn.setqflist({}, " ", { title = "replace (remaining): " .. pattern, items = fresh })
			end
			vim.notify(
				string.format("[replace] %d matches in %d files replaced", ct, cf),
				vim.log.levels.INFO,
				{ title = "replace" }
			)
		end)
	end)
end

--- Visual: паттерн из выделения, буквально.
function M.visual()
	local a = vim.fn.getpos("'<")
	local b = vim.fn.getpos("'>")
	local ok, lines = pcall(vim.fn.getregion, a, b, { type = "v" })
	local text = ok and lines and lines[1] or nil
	text = text and text:match("^%s*(.-)%s*$") or ""
	if text == "" then
		vim.notify("[replace] select text first", vim.log.levels.WARN, { title = "replace" })
		return
	end
	-- Буквально: \V + экранирование бэкслэша.
	M.project("\\V" .. text:gsub("\\", "\\\\"))
end

return M
