-- mini.pick/mini.extra behind _G shims (zero-dep, rg-optional).
_G._command_panel = function()
	_G._pick_extra("commands")
end

-- Безопасный вызов mini.pick / mini.extra: догружает mini.nvim через distro loader.
-- Ноль внешних зависимостей (rg/git опционально ускоряют builtin-пикеры).
local function _pick_ensure()
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

---Builtin-пикер mini.pick: files, grep_live, buffers, help, oldfiles, resume.
---@param fn string
---@param opts table|nil
_G._pick = function(fn, opts)
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
	local lib_searching = false
	local function lib_grep_fallback(bufnr, symbol)
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
		lib_searching = true
		vim.system(
			{ "rg", "--vimgrep", "--no-heading", "-F", symbol, dir },
			{ text = true, timeout = 10000 },
			function(obj)
				lib_searching = false
				if not obj or obj.code ~= 0 or not obj.stdout or obj.stdout == "" then
					return
				end
				local items = {}
				for _, line in ipairs(vim.split(obj.stdout, "\n", { plain = true })) do
					local f, l, c, text = line:match("^(.-):(%d+):(%d+):(.*)$")
					if f then
						items[#items + 1] = { filename = f, lnum = tonumber(l), col = tonumber(c), text = text }
					end
				end
				if #items == 0 then
					return
				end
				vim.fn.setqflist({}, " ", { title = "lib refs: " .. symbol, items = items })
				vim.cmd("copen")
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
				if not lib_grep_fallback(req_buf, req_symbol) then
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
				if not lib_grep_fallback(req_buf, req_symbol) then
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
