-- dev.project — модель project/workspace: корень, сессии, переключение.
--
-- Корень без git-бинарника: vim.fs ищет маркеры (go.work/go.mod/.git)
-- по файловой системе, git вызывается только как запасной вариант и
-- только при наличии executable. Сессии лежат там же, где раньше
-- (<leader>ss/sl): data-dir, имя от пути — формат НЕ меняем, старые
-- сессии подхватываются.
--
-- Автсейв: тихий, на VimLeavePre, opt-out (settings.project_autosave).
-- Авторестор: НЕТ (опасно для слабых VM и чужих машин) — вместо этого
-- одноразовый хинт при голом старте в каталоге с сессией.

local M = {}

local markers = { "go.work", "go.mod", ".git" }

--- Корень проекта для пути (или cwd): маркеры вверх, иначе глобальный cwd.
---@param path string?
---@return string
function M.root(path)
	path = path or vim.api.nvim_buf_get_name(0)
	if path == "" then
		path = vim.fn.getcwd(-1, -1)
	end
	-- Для файла ищем от его каталога; для каталога — от него самого.
	local st = vim.uv.fs_stat(path)
	local from = (st and st.type == "directory") and path or vim.fn.fnamemodify(path, ":h")
	local found = vim.fs.root(from, markers)
	if found then
		return vim.fs.normalize(found)
	end
	return vim.fs.normalize(vim.fn.getcwd(-1, -1))
end

local function session_dir()
	local dir = vim.fn.stdpath("data") .. "/sessions"
	vim.fn.mkdir(dir, "p")
	return dir
end

--- Имя файла сессии для корня (тот же формат, что <leader>ss).
---@param r string?
---@return string
function M.session_file(r)
	r = r or M.root()
	return session_dir() .. "/" .. r:gsub("[/\\:]", "%%") .. ".vim"
end

function M.save(r)
	r = r or M.root()
	vim.cmd("mksession! " .. vim.fn.fnameescape(M.session_file(r)))
	M.touch(r)
	vim.notify("[project] session saved: " .. r, vim.log.levels.INFO, { title = "project" })
end

function M.load(r)
	r = r or M.root()
	local f = M.session_file(r)
	if vim.fn.filereadable(f) ~= 1 then
		vim.notify("[project] no session for " .. r, vim.log.levels.WARN, { title = "project" })
		return false
	end
	vim.cmd("source " .. vim.fn.fnameescape(f))
	M.touch(r)
	return true
end

-- Реестр проектов: data/devproj.json { [path] = last_used }.
-- Сессии по имени необратимы (%% съедает разделители), поэтому ведём
-- свой журнал: пишется на save/VimEnter, читается переключалкой.
local function registry_path()
	return vim.fn.stdpath("data") .. "/devproj.json"
end

local function read_registry()
	local p = registry_path()
	local f = io.open(p, "r")
	if not f then
		return {}
	end
	local raw = f:read("*a")
	f:close()
	local ok, tbl = pcall(vim.json.decode, raw)
	if ok and type(tbl) == "table" then
		return tbl
	end
	return {}
end

local function write_registry(reg)
	local f = io.open(registry_path(), "w")
	if f then
		f:write(vim.json.encode(reg))
		f:close()
	end
end

--- Отметить проект как недавно использованный.
function M.touch(r)
	r = r or M.root()
	local reg = read_registry()
	reg[r] = os.time()
	-- Bounded: больше сотни проектов в списке не нужно.
	local n = 0
	for _ in pairs(reg) do
		n = n + 1
	end
	if n > 100 then
		local oldest, oldest_t = nil, nil
		for k, t in pairs(reg) do
			if not oldest_t or t < oldest_t then
				oldest, oldest_t = k, t
			end
		end
		if oldest then
			reg[oldest] = nil
		end
	end
	write_registry(reg)
end

--- Переключалка проектов: реестр + cwd, через vim.ui.select
--- (с telescope это пикер, без — штатный select).
function M.switch()
	local reg = read_registry()
	local items, seen = {}, {}
	for path, t in pairs(reg) do
		if vim.uv.fs_stat(path) then
			items[#items + 1] = { path = path, t = t }
			seen[path] = true
		end
	end
	local cwd = vim.fs.normalize(vim.fn.getcwd(-1, -1))
	if not seen[cwd] and vim.uv.fs_stat(cwd) then
		items[#items + 1] = { path = cwd, t = os.time() }
	end
	table.sort(items, function(a, b)
		return a.t > b.t
	end)
	if #items == 0 then
		vim.notify("[project] no known projects yet", vim.log.levels.INFO, { title = "project" })
		return
	end
	vim.ui.select(items, {
		prompt = "Switch project:",
		format_item = function(it)
			return it.path
		end,
	}, function(choice)
		if not choice then
			return
		end
		vim.cmd("cd " .. vim.fn.fnameescape(choice.path))
		M.touch(choice.path)
		-- Сессия есть — предлагаем, не навязываем (авторестор выключен).
		if vim.fn.filereadable(M.session_file(choice.path)) == 1 then
			local ans = vim.fn.confirm("Load session for " .. choice.path .. "?", "&Yes\n&No", 2)
			if ans == 1 then
				M.load(choice.path)
			end
		end
	end)
end

--- Wire: автсейв на выходе + touch на входе + хинт о сессии.
--- Вызывается один раз из keymap/dev.lua (дешево, три автокоманды).
local wired = false
function M.wire()
	if wired then
		return
	end
	wired = true
	local group = vim.api.nvim_create_augroup("DevProject", { clear = true })
	vim.api.nvim_create_autocmd("VimEnter", {
		group = group,
		once = true,
		desc = "project: touch cwd + hint saved session",
		callback = function()
			vim.schedule(function()
				-- touch — всегда (и с файлом-аргументом тоже): иначе проекты,
				-- открытые как `nvim file`, никогда не попадают в реестр
				-- переключалки. Хинт — только при голом старте, чтобы не
				-- спамить при каждом открытии файла.
				local r = M.root()
				M.touch(r)
				if vim.fn.argc() ~= 0 then
					return
				end
				if vim.fn.filereadable(M.session_file(r)) == 1 then
					vim.notify(
						"[project] session exists for this dir — <leader>sl to restore",
						vim.log.levels.INFO,
						{ title = "project" }
					)
				end
			end)
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		desc = "project: autosave session",
		callback = function()
			local ok_s, settings = pcall(require, "core.settings")
			if ok_s and settings.project_autosave == false then
				return
			end
			-- Тихий mksession: без нотифая на выходе (некому читать).
			pcall(vim.cmd, "mksession! " .. vim.fn.fnameescape(M.session_file()))
			pcall(M.touch)
		end,
	})
end

return M
