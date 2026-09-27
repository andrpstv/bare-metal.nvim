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
	---@return boolean ok true, если сканирование запущено (результат придёт в колбэке)
	local function lib_grep_fallback(bufnr, symbol, scope)
		if not symbol or symbol == "" then
			return false
		end
		if lib_searching then
			return false -- не плодим параллельные сканирования кэша модулей
		end
		if vim.fn.executable("rg") ~= 1 then
			return false
		end
		local fname = vim.api.nvim_buf_get_name(bufnr)
		if not require("modules.utils").is_go_lib(fname) then
			return false
		end
		local dir = vim.fn.fnamemodify(fname, ":p:h")
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
				vim.fn.setqflist({}, " ", { title = "lib refs: " .. symbol, items = items })
				if user_idle() then
					vim.cmd("copen")
				else
					-- Пользователь печатал или курсор ушёл: quickfix заполнен,
					-- но фокус не забираем.
					vim.notify("[lsp] " .. #items .. " lib refs in quickfix (not opening — you moved)", vim.log.levels.INFO, { title = "lsp" })
				end
			end
		)
		-- Уже запустили поиск: результат придёт в колбэке, UI свободен.
		return true
	end
	if opts.jump1 then
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
		local responded = false
		vim.defer_fn(function()
			if not responded and vim.api.nvim_buf_is_valid(req_buf) then
				vim.notify("[lsp] slow response (" .. scope .. "), server busy?", vim.log.levels.WARN, { title = "lsp" })
			end
		end, 2000)
		vim.lsp.buf_request(0, method, params, function(err, result)
			responded = true
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
