-- telescope.builtin behind _G shims (plenary vendored, rg-optional).
_G._command_panel = function()
	_G._pick_extra("commands")
end

-- Безопасный вызов telescope.builtin: догружает telescope.nvim через distro loader.
-- Ноль внешних зависимостей (rg/git опционально ускоряют builtin-пикеры).

-- DistroTrace. Отдельный маленький хук вместо обёртки снаружи: _G._pick_lsp
-- уже обёрнут в distro.tracehooks, а переписывать определения здесь означало бы
-- ловить собственный патч. Правило то же: выключенный трейс стоит одно
-- сравнение `if not t.enabled then` в начале каждой функции.
local function pick_trace()
	if not _G._pick_trace then
		local ok, t = pcall(require, "distro.trace")
		_G._pick_trace = ok and t or false
	end
	return _G._pick_trace
end

local pick_ensure_loaded = false

--- Собственно загрузка telescope (без трассировки) — вынесена отдельно, чтобы
--- picker:ensure не оборачивал рекурсию, и чтобы выключенный трейс вообще
--- не менял число require.
local _pick_ensure_inner

local function _pick_ensure()
	local t = pick_trace()
	if t and t.enabled and not pick_ensure_loaded then
		-- Первый вызов тянет telescope.nvim через loader.
		-- здесь фиксируем только факт инициализации пикера.
		local res = t.span("picker:ensure", _pick_ensure_inner)
		pick_ensure_loaded = true
		return res
	end
	return _pick_ensure_inner()
end

---@return table|nil telescope.builtin
_pick_ensure_inner = function()
	pcall(function()
		require("distro.loader").load("telescope.nvim")
	end)
	local ok, tele = pcall(require, "telescope.builtin")
	if not ok then
		vim.notify("[pick] telescope unavailable (:DistroInstall telescope.nvim)", vim.log.levels.ERROR, { title = "pick" })
		return nil
	end
	return tele
end

-- Вперёд объявленные тела: глобальные точки входа определены выше, но
-- ссылаются на эти функции. Без forward declaration Lua считает имя
-- глобальным — и _G._pick вызывает сам себя (stack overflow).
local _pick, _pick_extra

---Имя нашего пикера -> telescope.builtin. Единая таблица, чтобы хоткеи
---в tool.lua не знали про бэкенд.
local _tele_map = {
	-- файлы/поиск/буферы
	files = "find_files",
	grep_live = "live_grep",
	buffers = "buffers",
	help = "help_tags",
	oldfiles = "oldfiles",
	resume = "resume",
	-- бывшие extra-пикеры (теперь тоже telescope)
	commands = "commands",
	buf_lines = "current_buffer_fuzzy_find",
	git_branches = "git_branches",
	-- LSP (ветка без jump1 в _pick_lsp)
	document_symbol = "lsp_document_symbols",
	workspace_symbol_live = "lsp_dynamic_workspace_symbols",
	references = "lsp_references",
	implementation = "lsp_implementations",
	type_definition = "lsp_type_definitions",
	definition = "lsp_definitions",
}

---@param fn string
---@param opts table|nil
_G._pick = function(fn, opts)
	local t = pick_trace()
	if t and t.enabled then
		return t.span("picker:telescope", function()
			return _pick(fn, opts)
		end)
	end
	return _pick(fn, opts)
end

---Тело пикера (telescope): имя -> builtin.
---@param fn string
---@param opts table|nil
_pick = function(fn, opts)
	local tele = _pick_ensure()
	if not tele then
		return
	end
	local name = _tele_map[fn]
	if not name or type(tele[name]) ~= "function" then
		vim.notify("[pick] unknown picker: " .. fn, vim.log.levels.ERROR, { title = "pick" })
		return
	end
	tele[name](opts)
end

---@param fn string
---@param opts table|nil
_G._pick_extra = function(fn, opts)
	local t = pick_trace()
	if t and t.enabled then
		return t.span("picker:telescope", function()
			return _pick_extra(fn, opts)
		end)
	end
	return _pick_extra(fn, opts)
end

---@param fn string
---@param opts table|nil
_pick_extra = function(fn, opts)
	-- Тот же бэкенд: extra-имена живут в общей таблице выше.
	return _pick(fn, opts)
end

-- Флаг активного сканирования кэша модулей. Именно module-level: если держать
-- его внутри _G._pick_lsp, он пересоздаётся на каждом вызове, гард мёртвый, и
-- N нажатий gd дают N параллельных rg по go/pkg/mod (сотни МБ каждый).
local lib_searching = false

-- Кэш `go list` (import_path + cwd -> dir, TTL 5 мин): холодный go list
-- на большом монорепо — секунды (граф модулей), тёплый — 0.2с. Без кэша
-- каждый gd по qualified-символу платил холодную цену заново.
local go_list_cache = {}
local GO_LIST_TTL_NS = 300 * 1000000000

-- Учёт definition/type_definition-запроса, который УЖЕ ушёл в gopls.
-- Именно module-level, по той же причине, что и lib_searching выше: внутри
-- _G._pick_lsp это upvalue, пересоздаваемый на каждом вызове, и гард мёртв.
--
-- Это НЕ булев флаг и не "busy"-предупреждение. Две разные вещи:
--   1) настоящая отмена на проводе — замыкание, которое vim.lsp.buf_request
--      отдаёт вторым значением (lsp.lua:1298) и шлёт $/cancelRequest;
--   2) номер поколения — потому что отмена best-effort. Сервер без поддержки
--      cancel (и гонка на стороне gopls) всё равно может прислать результат.
--      Ответ с устаревшим поколением обязан уйти молча, не открыв пикер.
-- Поколение — обязательная часть контракта, отмена — оптимизация.
-- Счётчик живёт здесь, а не в замыкании: сравнивать его надо с ПОСЛЕДНИМ
-- запросом, то есть с тем, что находится вне функции.
--
-- Область действия намеренно узкая: только ветка opts.jump1 (gd и
-- type_definition). Ветка без jump1 уходит в telescope pickers, там запрос
-- принадлежит пикеру, и вытеснение сломало бы document_symbol/references/
-- implementation/workspace_symbol_live — они открывают UI сами.
local lsp_req = { gen = 0, inflight = nil }

-- Гонка LSP vs текст (jump1 + qualified): кто первый дал одиночную цель,
-- тот прыгает; второй молча сходит. Таблица на вызов (сбрасывается входом),
-- видна вложенным функциям как upvalue.
-- Зачем: здоровый gopls отвечает за 2–15мс («чистая скорость»), а текст-путь
-- стоит 30–350мс. Раньше qualified шёл только текстом и всегда платил его
-- цену; теперь быстрое — быстро, медленное — через фолбэк как раньше.
local race_state = nil

---Перейти к файлу без лишней перезагрузки: уже открытый буфер — через :b
---(нет detach-шторма LspDetach и повторных BufReadPost-цепей), иначе :edit.
---@param filename string
local function goto_file(filename)
	local b = vim.fn.bufnr(filename)
	if b > 0 and vim.api.nvim_buf_is_loaded(b) then
		pcall(vim.cmd, "buffer " .. b)
	else
		vim.cmd.edit(vim.fn.fnameescape(filename))
	end
end

---Победитель гонки прыгает, проигравший гаснет: помечаем done, отменяем
---LSP-запрос в полёте и сдвигаем поколение, чтобы его поздний ответ
---ушёл молча по существующему гарду.
local function race_win()
	if race_state then
		race_state.done = true
	end
	lsp_req.gen = lsp_req.gen + 1
	local prev = lsp_req.inflight
	lsp_req.inflight = nil
	if prev and type(prev.cancel) == "function" then
		pcall(prev.cancel)
	end
end

---LSP через telescope: definition|references|implementation|type_definition|
---document_symbol|workspace_symbol_live. opts.jump1: один результат — прыгнуть сразу.
---@param scope string
---@param opts table|nil
_G._pick_lsp = function(scope, opts)
	opts = opts or {}
	-- Сквозные фазы qualified-пути: tracehooks меряет только LSP-путь
	-- (keypress/request/response/cursor), а qualified идёт мимо gopls —
	-- секунды в нём были невидимы (жалоба: 3с, в трейсе пусто).
	-- t0 = вызов из маппинга ≈ keypress. Ошибки логирования никогда
	-- не должны ломать прыжок: весь qspan под pcall.
	local q_t0 = (vim.uv or vim.loop).hrtime()
	local function qspan(stage, detail)
		pcall(function()
			local tr = require("distro.trace")
			if tr and tr.enabled then
				tr.log(
					"pick_lsp/" .. tostring(scope),
					((vim.uv or vim.loop).hrtime() - q_t0) / 1e6,
					"phase:" .. stage .. (detail and (" " .. detail) or ""),
					nil,
					nil,
					{ kind = "phase", group = "pick_lsp/" .. tostring(scope) }
				)
			end
		end)
	end
	-- Новый вызов — новая гонка: сбрасываем состояние (см. race_state выше).
	race_state = nil
	if not _pick_ensure() then
		return
	end
	-- Честный текст ошибки сервера одной строкой (не "busy", если сервер ответил).
	local function err_text(err)
		local m = err and (err.message or (err.code and ("code " .. tostring(err.code)) or nil)) or nil
		m = tostring(m or "unknown error"):gsub("%s+", " ")
		return m:sub(1, 140)
	end
	-- Фолбэк для внешних либ (go/pkg/mod, GOROOT): gopls там часто отвечает
	-- "no package metadata". Тогда ищем символ текстовым rg по пакету в quickfix.
	-- Только для lib-буферов; в обычных файлах поведение прежнее.
	--
	-- ВАЖНО, почему это асинхронно: поиск идёт по КАТАЛОГУ пакета внутри
	-- go/pkg/mod — на машине потребителя это сотни мегабайт на HDD под
	-- Defender. Синхронный vim.fn.systemlist тут замораживал редактор на
	-- сотни мс — единицы секунд: нажатие gd на символе из go/pkg/mod
	-- (например mongo.Client) подвисало до завершения всего сканирования.
	-- Теперь UI не блокируется ни на одном этапе.
	---@param dir string|nil каталог для rg. nil = старый путь «каталог текущего буфера,
	---причём только если буфер сам является go-lib».
	---@return boolean ok true, если сканирование запущено (результат придёт в колбэке)
	local function lib_grep_fallback(bufnr, symbol, scope, dir)
		if not symbol or symbol == "" then
			return false
		end
		if lib_searching then
			return false -- не плодим параллельные сканирования кэша модулей
		end
		if vim.fn.executable("rg") ~= 1 then
			return false
		end
		if not dir then
			local fname = vim.api.nvim_buf_get_name(bufnr)
			if not require("modules.utils").is_go_lib(fname) then
				return false
			end
			dir = vim.fn.fnamemodify(fname, ":p:h")
		end
		if vim.uv.fs_stat(dir) == nil then
			return false
		end
		-- Снимок позиции пользователя на момент старта: copen не должен вырывать
		-- фокус, если к моменту ответа пользователь печатал или ушёл курсором.
		local start_win = vim.api.nvim_get_current_win()
		local start_pos = vim.api.nvim_win_get_cursor(0)
		local function user_idle()
			local m = vim.fn.mode()
			if m ~= "n" and m ~= "no" and m ~= "v" and m ~= "V" and m ~= "\22" then
				return false -- insert / cmdline / operator-pending: не перехватываем
			end
			if not vim.api.nvim_win_is_valid(start_win) or vim.api.nvim_get_current_win() ~= start_win then
				return false -- ушёл в другое окно
			end
			local cur = vim.api.nvim_win_get_cursor(start_win)
			return cur[1] == start_pos[1] and cur[2] == start_pos[2]
		end
		lib_searching = true
		vim.system(
			{ "rg", "--vimgrep", "--no-heading", "-F", symbol, dir },
			{ text = true, timeout = 10000 },
			function(obj)
				lib_searching = false
				-- NOTE: это FAST EVENT контекст (on_exit): здесь запрещены
				-- ЛЮБЫЕ API-вызовы, включая vim.notify (E5560). Поэтому всё
				-- тело — в vim.schedule, сразу и без исключений.
				vim.schedule(function()
				-- ВСЕ ветки отказа обязаны что-то сказать: потребитель полагается
				-- на return выше, а раньше тут был голый return — у пользователя не
				-- было ни перехода, ни quickfix, ни единого сообщения.
				if not obj then
					vim.notify("[lsp] text search for '" .. symbol .. "' produced no result", vim.log.levels.WARN, { title = "lsp" })
					return
				end
				if obj.code ~= 0 and obj.code ~= 1 then
					vim.notify("[lsp] text search failed (rg code " .. tostring(obj.code) .. "): " .. tostring(obj.stderr or ""), vim.log.levels.ERROR, { title = "lsp" })
					return
				end
				local items = {}
				if obj.stdout and obj.stdout ~= "" then
					-- rg --vimgrep prints ONE RECORD PER MATCH, not per line, so a
					-- line mentioning the symbol twice yields two entries at different
					-- columns (`func (db *Database) Client() *Client {`). Dedupe on
					-- file:line or the user scrolls past the same line twice.
					local seen = {}
					for _, line in ipairs(vim.split(obj.stdout, "\n", { plain = true })) do
						local f, l, c, text = line:match("^(.-):(%d+):(%d+):(.*)$")
						if f then
							local key = f .. ":" .. l
							if not seen[key] then
								seen[key] = true
								items[#items + 1] = { filename = f, lnum = tonumber(l), col = tonumber(c), text = text }
							end
						end
					end
				end
				-- A bare text search over a package returns every MENTION, not the
				-- declaration: `rg Client` in mongo-driver/mongo returns 2140 hits,
				-- most of them comments like "// Set up a new Client using ...".
				-- The user wants the one line that declares it, so when any real
				-- declaration is present, keep only those. The other ~2136 rows are
				-- noise they then have to scroll past.
				local esc = vim.pesc(symbol)
				-- NO ALTERNATION: Lua patterns have no `|`. "(type|var|const)" matches
				-- the literal text "type|var|const", so `type Client struct` and
				-- `var Client` silently failed to be recognised as declarations.
				-- One pattern per keyword instead.
				local def_pats = {
					"^%s*type%s+" .. esc .. "%f[%W]",
					"^%s*var%s+" .. esc .. "%f[%W]",
					"^%s*const%s+" .. esc .. "%f[%W]",
					"^%s*func%s+" .. esc .. "%f[%W]",
					"^%s*func%s*%([^)]*%)%s+" .. esc .. "%f[%W]",
				}
				-- Подмножество без методов: для `pkg.Name` метод `T.Name`
				-- почти всегда ложный след (ищем тип/функцию пакета).
				local plain_pats = {
					"^%s*type%s+" .. esc .. "%f[%W]",
					"^%s*var%s+" .. esc .. "%f[%W]",
					"^%s*const%s+" .. esc .. "%f[%W]",
					"^%s*func%s+" .. esc .. "%f[%W]",
				}
				local is_decl = function(t)
					for _, pat in ipairs(def_pats) do
						if t:match(pat) then
							return true
						end
					end
					return false
				end
				local is_plain_decl = function(t)
					for _, pat in ipairs(plain_pats) do
						if t:match(pat) then
							return true
						end
					end
					return false
				end
				local decls, rest = {}, {}
				for _, it in ipairs(items) do
					if is_decl(it.text) then
						decls[#decls + 1] = it
					else
						rest[#rest + 1] = it
					end
				end
				local n_decl = #decls
				if n_decl > 0 then
					-- declarations first, then the tail, so a single hit still jumps
					for _, it in ipairs(rest) do
						decls[#decls + 1] = it
					end
					items = decls
				end
				-- Ровно одно объявление среди шума упоминаний — или ровно одно
				-- НЕметод-объявление (`type`/`func` пакета вместо методов
				-- `T.Name`): прыгаем прямо в него, без quickfix
				-- (просьба: быстрый gd без квикфикса).
				local only_decl = nil
				if n_decl == 1 then
					only_decl = decls[1]
				else
					local plain = {}
					for _, it in ipairs(decls) do
						if is_plain_decl(it.text) then
							plain[#plain + 1] = it
						end
					end
					if #plain == 1 then
						only_decl = plain[1]
					elseif #plain > 1 then
						-- Несколько неметод-объявлений (подпакеты вроде
						-- options/ рядом с mongo/): берём мельчайшую глубину
						-- пути — объявление самого пакета, а не подпакета.
						-- В одном каталоге два одинаковых имени невозможны
						-- (ошибка компиляции), так что уникальный минимум
						-- однозначен.
						local best, best_depth, tied = nil, nil, false
						for _, it in ipairs(plain) do
							local _, nsep = (it.filename or ""):gsub("/", "/")
							if best_depth == nil or nsep < best_depth then
								best, best_depth, tied = it, nsep, false
							elseif nsep == best_depth then
								tied = true
							end
						end
						if best and not tied then
							only_decl = best
						end
					end
				end
				qspan("qual-rg-done", #items .. " hits decl=" .. tostring(only_decl ~= nil))
				-- Пустой результат = «ничего не найдено», а не «ошибка»: тот же
				-- тон, что у "no results for <scope>".
				if #items == 0 then
					vim.notify("[lsp] no results for " .. (scope or symbol) .. " (text search in package sources found nothing)", vim.log.levels.INFO, { title = "lsp" })
					return
				end
				-- vim.system delivers its callback in a FAST EVENT context, where
				-- nvim_exec2/setqflist are forbidden: E5560. Running setqflist and
				-- copen here threw and killed the whole search, so the text fallback
				-- for external packages never actually worked. Hop to the main loop.
				vim.schedule(function()
					if only_decl and user_idle() then
						if race_state and race_state.done then
							return -- гонку уже выиграл LSP
						end
						pcall(vim.cmd, "normal! m'")
						goto_file(only_decl.filename)
						pcall(vim.api.nvim_win_set_cursor, 0, { only_decl.lnum, (only_decl.col or 1) - 1 })
						qspan("qual-jump-direct", only_decl.filename)
						qspan("race-won", "text")
						race_win()
						race_win()
						vim.schedule(function()
							-- Первый тик после прыжка: кадр уже ушёл на
							-- отрисовку. Терминальный paint сюда не входит,
							-- но всё остальное (edit/treesitter/LSP-аттач
							-- нового корня) — уже случилось.
							qspan("qual-paint-tick")
						end)
						return
					end
					qspan("qual-jump-quickfix", #items .. " items")
					if race_state and race_state.done then
						return -- гонку уже выиграл LSP: не открываем поверх
					end
					vim.fn.setqflist({}, " ", { title = "lib refs: " .. symbol, items = items })
					if not user_idle() then
						vim.notify("[lsp] " .. #items .. " lib refs in quickfix (not opening — you moved)", vim.log.levels.INFO, { title = "lsp" })
						return
					end
					vim.cmd("copen")
				end)
			end)
		end
		)
		-- Уже запустили поиск: результат придёт в колбэке, UI свободен.
		return true
	end
	-- Qualified symbol in the USER's own file: `mongo.Client`, `errors.Is`, ...
	--
	-- The case that was actually reported. Cursor on the type after the dot,
	-- file is the user's own source, so `lib_grep_fallback`'s is_go_lib check
	-- was false and the text search never started: gd went to gopls only, and
	-- gopls was busy rebuilding the module index after the save that fired
	-- organizeImports. That is the multi-second freeze on mongo.Client.
	--
	-- So: read the buffer's import block, find the import whose last path
	-- segment (or explicit alias) matches the qualifier, let `go list` resolve
	-- it to a real directory (it handles GOROOT, the module cache and the
	-- @version suffix correctly), and hand that directory to the text search.
	-- Two async steps, UI never blocked, no gopls round-trip.
	local function go_qualified_grep(bufnr, qual, symbol, scope)
		if vim.fn.executable("go") ~= 1 or lib_searching then
			return false
		end
		if vim.api.nvim_buf_get_option(bufnr, "filetype") ~= "go" then
			return false
		end
		-- Scan the whole buffer for the import. The individual entries of a
		-- grouped `import ( ... )` block are separate lines that do NOT start
		-- with the keyword, so gating on `^%s*import` missed every one of them.
		-- Requiring the last path segment (or an explicit alias) to equal the
		-- qualifier is specific enough that a stray string literal will not match.
		local import_path
		for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
			local alias, p = l:match('^%s*(%a[%w]*)%s+"([^"]+)"')
			if not p then
				p = l:match('^%s*"([^"]+)"')
			end
			if p then
				local last = p:match("([^/]+)$")
				if alias == qual or (not alias and last == qual) then
					import_path = p
					break
				end
			end
		end
		if not import_path then
			return false
		end
		qspan("qual-import-scan", import_path)
		local cwd = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
		if vim.uv.fs_stat(cwd) == nil then
			return false
		end
		-- Общая дорога к rg — и для кэш-хита, и для ответа go list.
		local function got_dir(dir)
			vim.schedule(function()
				if not lib_grep_fallback(bufnr, symbol, scope, dir) then
					vim.notify("[lsp] text search for " .. symbol .. " in " .. import_path .. " could not start (falling back)", vim.log.levels.INFO, { title = "lsp" })
				end
			end)
		end
		do
			local now = (vim.uv or vim.loop).hrtime()
			local hit = go_list_cache[cwd .. "\0" .. import_path]
			if hit and (now - hit.at) < GO_LIST_TTL_NS and vim.uv.fs_stat(hit.dir) ~= nil then
				qspan("qual-go-list-cache-hit", hit.dir)
				got_dir(hit.dir)
				return true
			end
		end
		lib_searching = true
		-- GOFLAGS=-mod=mod: a module whose go.sum is incomplete makes `go list`
		-- fail outright, which is exactly the state a user is in right after
		-- adding an import and saving.
		local env = vim.fn.environ()
			env.GOFLAGS = "-mod=mod"
		vim.system({ "go", "list", "-f", "{{.Dir}}", import_path }, { text = true, cwd = cwd, env = env, timeout = 10000 }, function(res)
			-- Release the guard BEFORE delegating: lib_grep_fallback takes it
			-- itself for the duration of the rg scan.
			lib_searching = false
			-- NOTE: это тоже FAST EVENT (on_exit): API, файловый I/O трейса —
			-- только из main loop. Чистый Lua (trim, таблицы) безопасен и здесь,
			-- но целиком в schedule проще и единообразно с rg-колбэком выше.
			vim.schedule(function()
			-- Every refusal path must say something. A silent return here is what
			-- made this look like "the fix did nothing" instead of "it failed".
			if not res then
				vim.notify("[lsp] go list produced no result for " .. import_path, vim.log.levels.WARN, { title = "lsp" })
				return
			end
			if res.code ~= 0 then
				vim.notify("[lsp] go list failed for " .. import_path .. ": " .. (res.stderr or ""):gsub("%s+", " "):sub(1, 160), vim.log.levels.WARN, { title = "lsp" })
				return
			end
			local dir = vim.trim(res.stdout or "")
			if dir == "" then
				vim.notify("[lsp] go list gave an empty directory for " .. import_path, vim.log.levels.WARN, { title = "lsp" })
				return
			end
			qspan("qual-go-list", dir)
			go_list_cache[cwd .. "\0" .. import_path] = { dir = dir, at = (vim.uv or vim.loop).hrtime() }
			got_dir(dir)
			end)
		end)
		return true
	end

	if opts.jump1 then
		-- Квалифицированный символ в СВОЁМ файле: курсор на типе после точки
		-- (`mongo.Client`, `errors.Is`). cWORD даёт `mongo.Client`, cWORD даёт
		-- квалификатор, а <cword> — имя типа, когда курсор стоит после точки.
		-- Именно этот случай жаловался как «gd на mongo.Client тупит».
		if vim.bo.filetype == "go" then
			-- NB: req_buf / req_symbol are declared LATER in this branch, so
			-- referencing them here saw nil and the branch never fired.
			-- Read the cursor state directly instead.
			local gbuf = vim.api.nvim_get_current_buf()
			local full = vim.fn.expand("<cWORD>")
			local cur_word = vim.fn.expand("<cword>")
			local qual, sym = full:match("^([%a][%w_]*)%.([%a][%w_]*)$")
			-- cur_word == sym means the cursor sits on the TYPE after the dot,
			-- which is what the user wants. Cursor on the qualifier means they
			-- want the package itself, and gopls answers that quickly - leave it.
			--
			-- ГОНКА (race_state): текст-путь стартует, но НЕ возвращается —
			-- ниже параллельно уходит LSP-запрос. Кто первый дал одиночную
			-- цель, тот прыгает (флаг done); второй молча сходит. Здоровый
			-- gopls отвечает за миллисекунды, больной — висит, и тогда
			-- выигрывает текст как раньше. Худший случай не хуже текста.
			if qual and sym and cur_word == sym then
				if go_qualified_grep(gbuf, qual, sym, scope) then
					race_state = { text = true, done = false }
				end
			end
		end
		local method = "textDocument/" .. (scope == "type_definition" and "typeDefinition" or scope == "references" and "references" or scope == "implementation" and "implementation" or "definition")
		if #vim.lsp.get_clients({ bufnr = 0, method = method }) == 0 then
			-- В гонке текст-путь уже бежит и скажет сам (плюс watchdog
			-- сообщит о смерти сервера отдельно): не спамим.
			if not (race_state and race_state.text) then
				vim.notify("[lsp] no client for " .. scope .. " here", vim.log.levels.INFO, { title = "lsp" })
			end
			return
		end
		local params = vim.lsp.util.make_position_params(0, "utf-16")
		-- Async: никогда не фризим UI (раньше buf_request_sync(2000) висел на висящем gopls).
		-- Сторож: если ответа нет 2с — предупреждаем (раньше это делал сам timeout sync).
		-- Анти-телепорт: прыгаем только если курсор не ушёл (холодный gopls на
		-- внешних либах отвечает через секунды); иначе — в пикер, без сюрпризов.
		local req_buf = vim.api.nvim_get_current_buf()
		local req_pos = vim.api.nvim_win_get_cursor(0)
		local req_symbol = vim.fn.expand("<cword>")
		-- Go external packages (go/pkg/mod, GOROOT): go straight to the text
		-- search, do NOT queue behind gopls first.
		--
		-- Why: on these buffers gopls is usually mid-rebuild of the module index
		-- (a save fires `source.organizeImports` at lua/core/go.lua:50, which is
		-- what pulls the imported package in), and it answers "no package
		-- metadata" anyway. So the old order - wait for gopls, and only then run
		-- lib_grep_fallback from its callback - meant the user's gd sat in the
		-- queue behind a multi-second package build before the rg search even
		-- started. That is the "gd is slow on mongo.Client" report, and the
		-- 5249 ms incident recorded in docs/distro.
		--
		-- rg over the package directory is both faster and correct here. If it
		-- cannot start (no rg, not a lib buffer, a scan already in flight) we
		-- return false and fall through to the normal gopls path unchanged.
		if require("modules.utils").is_go_lib(vim.api.nvim_buf_get_name(req_buf)) then
			if lib_grep_fallback(req_buf, req_symbol, scope) then
				return
			end
		end
		-- Новый gd = новое поколение. Прежний запрос в полёте вытесняется:
		-- отменяем на проводе, после чего его поздний ответ (если сервер
		-- проигнорирует cancel) отбросится проверкой поколения в колбэке.
		local gen = lsp_req.gen + 1
		lsp_req.gen = gen
		if race_state then
			race_state.gen = gen
		end
		local prev = lsp_req.inflight
		if prev and type(prev.cancel) == "function" then
			pcall(prev.cancel)
		end
		lsp_req.inflight = nil
		local responded = false
		vim.defer_fn(function()
			-- Сторож живёт только у САМОГО СВЕЖЕГО запроса. Иначе N нажатий
			-- дают N одинаковых "server busy?" от запросов, уже отменённых и
			-- пользователю не нужных.
			if gen == lsp_req.gen and not responded and vim.api.nvim_buf_is_valid(req_buf) then
				if not (race_state and race_state.done) then
					vim.notify("[lsp] slow response (" .. scope .. "), server busy?", vim.log.levels.WARN, { title = "lsp" })
				end
			end
		end, 2000)
		local _, cancel = vim.lsp.buf_request(0, method, params, function(err, result)
			-- Ответ на ВЫТЕСНЕННЫЙ запрос: уходим молча. Ни прыжка в устаревшую
			-- позицию, ни пикера поверх того, что открыл более новый запрос, ни
			-- rg-фолбэка. Это и есть защита от гонки, а не только отмена.
			if gen ~= lsp_req.gen then
				return
			end
			responded = true
			if lsp_req.inflight and lsp_req.inflight.gen == gen then
				lsp_req.inflight = nil
			end
			if err then
				-- Сервер ответил ошибкой (не висение!): показываем её текст,
				-- а для внешних либ пробуем текстовый фолбэк вместо пустоты.
				-- В гонке текст-путь уже бежит сам: дублировать поиск и
				-- спамить не нужно, он скажет сам.
				if race_state and race_state.text then
					return
				end
				if not lib_grep_fallback(req_buf, req_symbol, scope) then
					vim.notify("[lsp] " .. scope .. " failed: " .. err_text(err), vim.log.levels.WARN, { title = "lsp" })
				end
				return
			end
			local locs = {}
			if result then
				if result.uri then
					locs[1] = result
				else
					locs = result
				end
			end
			if #locs == 1 then
				local ok_item, item = pcall(vim.lsp.util.locations_to_items, locs, "utf-16")
				item = ok_item and item[1] or nil
				if item then
					if race_state and race_state.done then
						return -- гонку уже выиграл текст
					end
					local cur = vim.api.nvim_win_get_cursor(0)
					if vim.api.nvim_get_current_buf() == req_buf and cur[1] == req_pos[1] and cur[2] == req_pos[2] then
						if race_state then
							race_state.done = true
							qspan("race-won", "lsp")
						end
						pcall(vim.cmd, "normal! m'") -- <C-o> назад после прыжка
						local same = item.bufnr == req_buf
							or item.filename == vim.api.nvim_buf_get_name(req_buf)
						if not same then
							-- NOTE: :edit на ТОТ ЖЕ файл шлёт LspDetach (0.12) и
							-- будит GoplsWatchdog ложным рестартом — тот же буфер
							-- не перезагружаем, только двигаем курсор.
							goto_file(item.filename)
						end
						pcall(vim.api.nvim_win_set_cursor, 0, { item.lnum, item.col - 1 })
						return
					end
					-- Курсор ушёл, пока gopls думал: не телепортируем, показываем пикер.
					vim.notify("[lsp] result arrived after you moved — opening picker", vim.log.levels.INFO, { title = "lsp" })
				end
			elseif #locs == 0 then
				-- В гонке текст-путь уже бежит: молча отдаём ему UX.
				if race_state and race_state.text then
					return
				end
				if not lib_grep_fallback(req_buf, req_symbol, scope) then
					vim.notify("[lsp] no results for " .. scope, vim.log.levels.INFO, { title = "lsp" })
				end
				return
			end
			-- 2+ результатов: падаем в пикер ниже (таблица _tele_map).
			-- Но не поверх выигравшего текста.
			if race_state and race_state.done then
				return
			end
			_pick(scope)
		end)
		-- Запрос в полёте: следующий gd вытеснит именно его, а не что попало.
		if gen == lsp_req.gen then
			lsp_req.inflight = { gen = gen, cancel = type(cancel) == "function" and cancel or nil }
		end
		return
	end
	if not _pick_ensure() then
		return
	end
	_pick(scope)
end

---Grep по визуальному выделению (первая строка, буквально).
---NOTE: map("v",...) вызывает функцию уже ПОСЛЕ выхода из visual, поэтому
---getpos("v")/visualmode() пусты. Берём метки '< и '> — они живут дольше режима.
_G._pick_grep_visual = function()
	local tele = _pick_ensure()
	if not tele then
		return
	end
	local a = vim.fn.getpos("'<")
	local b = vim.fn.getpos("'>")
	local ok, lines = pcall(vim.fn.getregion, a, b, { type = "v" })
	local text = ok and lines and lines[1] or nil
	text = text and text:match("^%s*(.-)%s*$") or ""
	if text == "" then
		vim.notify("[pick] select text first", vim.log.levels.WARN, { title = "pick" })
		return
	end
	tele.grep_string({ search = text })
end

-- Warm-предзагрузка telescope на первом idle (§5b.1 speed-program).
-- Первый gd/ff в сессии тянул плагин холодным через loader;
-- греем один раз заранее.
-- Два триггера, кто первый — тот и греет (одноразовый флаг):
--   1) VimEnter +300мс таймер;
--   2) CursorHold один раз (первая пауза пользователя).
-- headless/SYNC — возврат без прогрева (детерминизм); lean/weak — тоже warm.
-- telescope отсутствует — тихий return, ноль notify (pcall везде).
local _pick_warmed = false

local function _pick_warm()
	if _pick_warmed then
		return
	end
	_pick_warmed = true
	if vim.env.NVIM_DISTRO_SYNC == "1" then
		return
	end
	if #vim.api.nvim_list_uis() == 0 then
		return
	end
	pcall(function()
		require("distro.loader").load("telescope.nvim")
	end)
	pcall(require, "telescope")
	pcall(require, "telescope.builtin")
end

do
	local grp = vim.api.nvim_create_augroup("PickWarm", { clear = true })
	-- 1) первая пауза пользователя (CursorHold один раз)
	vim.api.nvim_create_autocmd("CursorHold", {
		group = grp,
		once = true,
		desc = "pick: warm telescope on first idle",
		callback = function()
			vim.schedule(_pick_warm)
		end,
	})
	-- 2) 300мс после входа (таймер останавливается на VimLeavePre, как в loader.boot)
	local warm_timer = vim.uv.new_timer()
	local function warm_later()
		warm_timer:start(300, 0, vim.schedule_wrap(function()
			_pick_warm()
		end))
	end
	vim.api.nvim_create_autocmd("VimEnter", {
		group = grp,
		once = true,
		desc = "pick: warm telescope 300ms after enter",
		callback = warm_later,
	})
	-- pick.lua грузится из keymap/init при старте (до VimEnter), но страховка
	-- от позднего require: если вход уже был — таймер сразу.
	if vim.v.vim_did_enter ~= 0 then
		warm_later()
	end
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = grp,
		once = true,
		desc = "pick: cancel warm timer",
		callback = function()
			pcall(function()
				warm_timer:stop()
			end)
			pcall(function()
				warm_timer:close()
			end)
		end,
	})
end
