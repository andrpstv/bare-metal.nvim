-- dev.terminal — project-local persistent terminals на встроенном :terminal.
--
-- Почему свой, а не toggleterm.nvim: builtin-терминал уже есть везде
-- (включая Windows), persist/per-project/toggle/send — это ~180 строк без
-- нового плагина, без его keymap-конвенций и без сюрпризов на слабых VM.
-- Портабельность: никаких предположений о shell (дефолт vim.o.shell,
-- который core уже настраивает под Windows/pwsh).
--
-- Модель: один долгоживущий терминал на корень проекта (dev.project.root),
-- job и скролбэк переживают toggle. Окно — расходник (float/split/vsplit).

local M = {}

--- bufnr терминалов по корню проекта. Ключ — нормализованный путь.
local terms = {}

local function root()
	local ok, proj = pcall(require, "dev.project")
	if ok and proj.root then
		return proj.root()
	end
	return vim.fn.getcwd(-1, -1)
end

--- Жив ли терминал (буфер валиден + job бежит).
local function alive(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	local job = vim.b[buf] and vim.b[buf].terminal_job_id
	if not job then
		return false
	end
	-- Мёртвый job: pcall jobwait c таймаутом 0 не трогает живой процесс.
	local ok, res = pcall(vim.fn.jobwait, { job }, 0)
	return ok and res and res[1] == -1
end

--- Окно, где сейчас показан буфер (или nil).
local function win_of(buf)
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(w) == buf then
			return w
		end
	end
	return nil
end

local function float_win(buf)
	local width = math.min(140, math.floor(vim.o.columns * 0.85))
	local height = math.min(30, math.floor(vim.o.lines * 0.7))
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)
	return vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " terminal ",
	})
end

--- Открыть (или создать) терминал проекта в окне вида kind.
---@param kind "float"|"split"|"vsplit"
---@return integer|nil bufnr
function M.open(kind)
	kind = kind or "float"
	if #vim.api.nvim_list_uis() == 0 then
		vim.notify("[terminal] needs a UI (headless has no windows)", vim.log.levels.WARN, { title = "terminal" })
		return nil
	end
	local r = root()
	local buf = terms[r]
	if not alive(buf) then
		buf = nil
	end
	if buf then
		local w = win_of(buf)
		if w then
			vim.api.nvim_set_current_win(w)
			vim.cmd("startinsert")
			return buf
		end
	else
		buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		terms[r] = buf
	end
	if kind == "float" then
		float_win(buf)
	elseif kind == "split" then
		vim.cmd("botright split")
		vim.api.nvim_win_set_buf(0, buf)
	else
		vim.cmd("botright vsplit")
		vim.api.nvim_win_set_buf(0, buf)
	end
	if not alive(buf) or not (vim.b[buf] and vim.b[buf].terminal_job_id) then
		-- Новый буфер: стартуем shell в корне проекта. lcd window-local,
		-- чтобы :terminal унаследовал cwd проекта, а не окна вызова.
		vim.cmd("lcd " .. vim.fn.fnameescape(r))
		vim.api.nvim_buf_call(buf, function()
			vim.cmd("terminal")
		end)
		vim.bo[buf].bufhidden = "hide"
	end
	vim.cmd("startinsert")
	return buf
end

--- Toggle: виден — спрятать (job жив), скрыт — показать float.
function M.toggle()
	local r = root()
	local buf = terms[r]
	if buf and win_of(buf) then
		vim.api.nvim_win_hide(win_of(buf))
		return
	end
	M.open("float")
end

--- Послать команду в терминал проекта, не уводя фокус.
---@param cmd string команда без trailing <CR> (добавим сами)
---@param show boolean? показать окно терминала после отправки
function M.send(cmd, show)
	if not cmd or cmd == "" then
		return
	end
	local r = root()
	local buf = terms[r]
	if not alive(buf) then
		buf = M.open("split")
		if not buf then
			return
		end
		-- Вернуть фокус: open ушёл в insert терминала.
		vim.cmd("wincmd p")
	end
	local job = vim.b[buf].terminal_job_id
	if not job then
		vim.notify("[terminal] no shell job in project terminal", vim.log.levels.ERROR, { title = "terminal" })
		return
	end
	vim.api.nvim_chan_send(job, cmd .. "\n")
	if show then
		local w = win_of(buf)
		if w then
			vim.api.nvim_set_current_win(w)
		else
			M.open("float")
			return
		end
		vim.cmd("startinsert")
	end
end

--- Забыть терминал проекта (следующий open создаст новый shell).
function M.wipe()
	local r = root()
	local buf = terms[r]
	terms[r] = nil
	if buf and vim.api.nvim_buf_is_valid(buf) then
		local job = vim.b[buf].terminal_job_id
		if job then
			pcall(vim.fn.jobstop, job)
		end
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end

return M
