-- mini.pick/mini.extra behind _G shims (zero-dep, rg-optional).
_G._command_panel = function()
	_G._pick_extra("commands")
end

-- Безопасный вызов mini.pick / mini.extra: догружает mini.nvim через distro loader.
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

--- Собственно загрузка mini.pick (без трассировки) — вынесена отдельно, чтобы
--- picker:ensure не оборачивал рекурсию, и чтобы выключенный трейс вообще
--- не менял число require.
local _pick_ensure_inner

local function _pick_ensure()
	local t = pick_trace()
	if t and t.enabled and not pick_ensure_loaded then
		-- Первый вызов тянет mini.nvim через loader (до 121 модуля на холодном
		-- старте). Стоимость самого require уходит в loader:load/mini.nvim;
		-- здесь фиксируем только факт инициализации пикера.
		local res = t.span("picker:ensure", _pick_ensure_inner)
		pick_ensure_loaded = true
		return res
	end
	return _pick_ensure_inner()
end

---@return table|nil mini.pick
_pick_ensure_inner = function()
	pcall(function()
		require("distro.loader").load("mini.nvim")
	end)
	local ok, pick = pcall(require, "mini.pick")
	if not ok then
		vim.notify("[pick] mini.pick unavailable", vim.log.levels.ERROR, { title = "pick" })
		return nil
	end
	return pick
end

-- Вперёд объявленные тела: глобальные точки входа определены выше, но
-- ссылаются на эти функции. Без forward declaration Lua считает имя
-- глобальным — и _G._pick вызывает сам себя (stack overflow).
local _pick, _pick_extra

---Builtin-пикер mini.pick: files, grep_live, buffers, help, oldfiles, resume.
---@param fn string
---@param opts table|nil
_G._pick = function(fn, opts)
	local t = pick_trace()
	if t and t.enabled then
		-- Один span на весь вызов: builtin-пикер сам спискает и рисует
		-- элементы внутри, трейсить каждый экран не нужно.
		return t.span("picker:mini.pick", function()
			return _pick(fn, opts)
		end)
	end
	return _pick(fn, opts)
end

---Тело builtin-пикера (mini.pick): рисует и спискает элементы сам.
---@param fn string
---@param opts table|nil
_pick = function(fn, opts)
	local pick = _pick_ensure()
	if not pick then
		return
	end
	if type(pick.builtin[fn]) ~= "function" then
		vim.notify("[pick] unknown builtin picker: " .. fn, vim.log.levels.ERROR, { title = "pick" })
		return
	end
	pick.builtin[fn](opts)
end

---Пикеры mini.extra (тот же монорепо): commands, buf_lines, git_branches, history...
---@param fn string
---@param opts table|nil
_G._pick_extra = function(fn, opts)
	local t = pick_trace()
	if t and t.enabled then
		return t.span("picker:mini.extra", function()
			return _pick_extra(fn, opts)
		end)
	end
	return _pick_extra(fn, opts)
end

---@param fn string
---@param opts table|nil
_pick_extra = function(fn, opts)
	if not _pick_ensure() then
		return
	end
	local ok, extra = pcall(require, "mini.extra")
	if not ok or type(extra.pickers[fn]) ~= "function" then
		vim.notify("[pick] unknown extra picker: " .. fn, vim.log.levels.ERROR, { title = "pick" })
		return
	end
	extra.pickers[fn](opts)
end

-- Флаг активного сканирования кэша модулей. Именно module-level: если держать
-- его внутри _G._pick_lsp, он пересоздаётся на каждом вызове, гард мёртвый, и
-- N нажатий gd дают N параллельных rg по go/pkg/mod (сотни МБ каждый).
local lib_searching = false

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
-- type_definition). Ветка без jump1 уходит в mini.extra pickers, там запрос
-- принадлежит пикеру, и вытеснение сломало бы document_symbol/references/
-- implementation/workspace_symbol_live — они открывают UI сами.
local lsp_req = { gen = 0, inflight = nil }

---LSP через mini.extra: definition|references|implementation|type_definition|
---document_symbol|workspace_symbol_live. opts.jump1: один результат — прыгнуть сразу.
---@param scope string
---@param opts table|nil
_G._pick_lsp = function(scope, opts)
	opts = opts or {}
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
					for _, line in ipairs(vim.split(obj.stdout, "\n", { plain = true })) do
						local f, l, c, text = line:match("^(.-):(%d+):(%d+):(.*)$")
						if f then
							items[#items + 1] = { filename = f, lnum = tonumber(l), col = tonumber(c), text = text }
						end
					end
				end
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
					vim.fn.setqflist({}, " ", { title = "lib refs: " .. symbol, items = items })
					if not user_idle() then
						vim.notify("[lsp] " .. #items .. " lib refs in quickfix (not opening — you moved)", vim.log.levels.INFO, { title = "lsp" })
						return
					end
					vim.cmd("copen")
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
		local cwd = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
		if vim.uv.fs_stat(cwd) == nil then
			return false
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
			-- go list's callback is a FAST EVENT context. lib_grep_fallback
			-- starts with nvim_get_current_win / nvim_win_get_cursor, which are
			-- forbidden there (E5560) - so the whole thing died before rg ran.
			-- Hop to the main loop first, then delegate.
			vim.schedule(function()
				if not lib_grep_fallback(bufnr, symbol, scope, dir) then
					vim.notify("[lsp] text search for " .. symbol .. " in " .. import_path .. " could not start (falling back)", vim.log.levels.INFO, { title = "lsp" })
				end
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
			if qual and sym and cur_word == sym then
				if go_qualified_grep(gbuf, qual, sym, scope) then
					return
				end
			end
		end
		local method = "textDocument/" .. (scope == "type_definition" and "typeDefinition" or scope == "references" and "references" or scope == "implementation" and "implementation" or "definition")
		if #vim.lsp.get_clients({ bufnr = 0, method = method }) == 0 then
			vim.notify("[lsp] no client for " .. scope .. " here", vim.log.levels.INFO, { title = "lsp" })
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
				vim.notify("[lsp] slow response (" .. scope .. "), server busy?", vim.log.levels.WARN, { title = "lsp" })
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
					local cur = vim.api.nvim_win_get_cursor(0)
					if vim.api.nvim_get_current_buf() == req_buf and cur[1] == req_pos[1] and cur[2] == req_pos[2] then
						vim.cmd.edit(vim.fn.fnameescape(item.filename))
						pcall(vim.api.nvim_win_set_cursor, 0, { item.lnum, item.col - 1 })
						return
					end
					-- Курсор ушёл, пока gopls думал: не телепортируем, показываем пикер.
					vim.notify("[lsp] result arrived after you moved — opening picker", vim.log.levels.INFO, { title = "lsp" })
				end
			elseif #locs == 0 then
				if not lib_grep_fallback(req_buf, req_symbol, scope) then
					vim.notify("[lsp] no results for " .. scope, vim.log.levels.INFO, { title = "lsp" })
				end
				return
			end
			-- 2+ результатов: падаем в пикер ниже
			local ok2, extra2 = pcall(require, "mini.extra")
			if ok2 then
				extra2.pickers.lsp({ scope = scope })
			end
		end)
		-- Запрос в полёте: следующий gd вытеснит именно его, а не что попало.
		if gen == lsp_req.gen then
			lsp_req.inflight = { gen = gen, cancel = type(cancel) == "function" and cancel or nil }
		end
		return
	end
	local ok, extra = pcall(require, "mini.extra")
	if not ok then
		vim.notify("[pick] mini.extra unavailable", vim.log.levels.ERROR, { title = "pick" })
		return
	end
	extra.pickers.lsp({ scope = scope })
end

---Grep по визуальному выделению (первая строка, буквально).
_G._pick_grep_visual = function()
	local pick = _pick_ensure()
	if not pick then
		return
	end
	local a = vim.fn.getpos("v")
	local b = vim.fn.getpos(".")
	local ok, lines = pcall(vim.fn.getregion, a, b, { type = vim.fn.visualmode() })
	local text = ok and lines and lines[1] or nil
	text = text and text:match("^%s*(.-)%s*$") or ""
	if text == "" then
		vim.notify("[pick] select text first", vim.log.levels.WARN, { title = "pick" })
		return
	end
	pick.builtin.grep({ pattern = text, method = "plain" })
end
