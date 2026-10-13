-- dev.termmarks — статус команд в :terminal (как декорации shell-integration в VS Code):
-- ✓/✗ в signcolumn на строке приглашения + виртуальный текст (`exit 2 · 3.4s`).
-- Почему свой: ядро (defaults.lua) разбирает только OSC 133;A (метки приглашений для [[ / ]]),
-- а C/D (старт вывода / код возврата) не трогает; плагин ради ~60 строк не нужен.
-- Цена на TermRequest — один string.match по префиксу; остальные OSC отбрасываются сразу.
local M = {}

local ns = vim.api.nvim_create_namespace("dev_termmarks")
local prompt_ns -- namespace меток приглашений ядра, создаётся лениво (get_namespaces)
local started = {} ---@type table<integer, {t: integer, row: integer}> буфер -> момент/строка OSC C
local augroup

M.last_done = nil ---@type {buf: integer, code: integer, sec: number, cmd: string, time: number}|nil

---@param seq string
---@return {kind: "C"}|{kind: "D", code: integer}|nil
function M._parse(seq)
	if seq:sub(1, 6) ~= "\027]133;" then
		return nil
	end
	local kind = seq:sub(7, 7)
	if kind == "C" then
		return { kind = "C" }
	elseif kind == "D" then
		local code = seq:match("^D;(%-?%d+)", 7)
		-- D без кода = неизвестный итог: метку не ставим
		return code and { kind = "D", code = tonumber(code) } or nil
	end
end

---@param sec number
---@return string|nil -- nil для < 1с: быстрые команды не шумят
function M._fmt_duration(sec)
	if sec < 1 then
		return nil
	elseif sec < 60 then
		return string.format("%.1fs", sec)
	end
	return string.format("%dm%02ds", math.floor(sec / 60), math.floor(sec % 60))
end

---@param line string
---@return string -- текст команды после prompt, до 24 символов
function M._cmd_from_line(line)
	-- Приглашение кончается символом и пробелом («❯ », «$ », «% »…). Берём ПЕРВОЕ вхождение:
	-- по последнему `echo $HOME > out` обрезался бы до «out». ❯/➜ — многобайтные, отдельно от класса.
	local cmd = line:match("❯%s+(.*)$") or line:match("➜%s+(.*)$") or line:match("^[^$%%>#]-[$%%>#]%s+(.*)$") or line
	cmd = vim.trim(cmd)
	if vim.fn.strchars(cmd) > 24 then
		cmd = vim.fn.strcharpart(cmd, 0, 23) .. "…"
	end
	return cmd
end

---@param ld {buf: integer, code: integer, sec: number, cmd: string, time: number}|nil
---@param now_ms number
---@return string -- табличный сегмент или ""
function M._badge(ld, now_ms)
	if not ld or not vim.api.nvim_buf_is_valid(ld.buf) then
		return ""
	end
	-- Старше 60 секунд — скрыть
	if (now_ms - ld.time) > 60000 then
		return ""
	end
	local cmd = ld.cmd ~= "" and (" " .. ld.cmd:gsub("%%", "%%%%") .. " ") or " "
	local result = ld.code == 0 and "%#StlMT#✓" or ("%#DiagnosticError#✗ " .. ld.code)
	local dur = M._fmt_duration(ld.sec) or ""
	if dur ~= "" then
		dur = " " .. dur .. " "
	end
	return "%@v:lua._tl_term_click@%#StlSep#│%#StlMeta# ⌁" .. cmd .. result .. "%#StlMeta#" .. dur .. "%X"
end

---@param buf integer
---@param code integer
---@param sec number|nil
---@param fallback_row integer 1-based строка курсора на D
local function mark(buf, code, sec, fallback_row)
	prompt_ns = prompt_ns or vim.api.nvim_get_namespaces()["nvim.terminal.prompt"]
	local row = fallback_row - 1
	local st = started[buf]
	if st and prompt_ns then
		-- последнее приглашение на/выше строки старта команды = приглашение этой команды
		local m = vim.api.nvim_buf_get_extmarks(buf, prompt_ns, { st.row - 1, 0 }, 0, { limit = 1 })[1]
		row = m and m[2] or row
	end
	if row < 0 or row >= vim.api.nvim_buf_line_count(buf) then
		return
	end
	local ok = code == 0
	local dur = sec and M._fmt_duration(sec)
	local virt = {}
	if not ok then
		virt[#virt + 1] = { "exit " .. code, "DiagnosticError" }
	end
	if dur then
		virt[#virt + 1] = { (#virt > 0 and " · " or "") .. dur, "Comment" }
	end
	if #virt > 0 then
		table.insert(virt, 1, { "  ", "Normal" })
	end
	pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
		id = row + 1, -- повтор D на той же строке заменяет метку
		sign_text = ok and "✓" or "✗",
		sign_hl_group = ok and "DiagnosticOk" or "DiagnosticError",
		virt_text = #virt > 0 and virt or nil,
		priority = 200,
	})
	-- Если терминал не видно — запомнить в last_done для tabline и вызвать bear
	if #(vim.fn.win_findbuf(buf) or {}) == 0 then
		local cmd = ""
		if st then
			-- OSC C шлёт preexec уже после Enter: курсор на строке ниже команды. Берём строку выше,
			-- пустую — пропускаем (команду печатают и прямо в строке вывода, как printf в тесте).
			for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, math.max(0, st.row - 2), st.row, false)) do
				local c = M._cmd_from_line(l)
				if c ~= "" then
					cmd = c
					break
				end
			end
		end
		M.last_done = { buf = buf, code = code, sec = sec or 0, cmd = cmd, time = vim.uv.now() }
		pcall(function()
			require("dev.bear").done("term", code == 0)
		end)
		vim.cmd.redrawtabline()
	end
end

function M.setup()
	if augroup then
		return
	end
	augroup = vim.api.nvim_create_augroup("dev_termmarks", { clear = true })
	vim.api.nvim_create_autocmd("TermRequest", {
		group = augroup,
		desc = "[term] command status marks from OSC 133;C/D",
		callback = function(ev)
			local p = M._parse(ev.data.sequence)
			if not p then
				return
			end
			local buf = ev.buf
			if p.kind == "C" then
				started[buf] = { t = vim.uv.hrtime(), row = ev.data.cursor[1] }
			elseif started[buf] then
				-- D без C (первый промпт, пустой Enter — zsh не зовёт preexec) не относится ни к
				-- одной команде: без C метка встала бы на случайную строку.
				local st = started[buf]
				mark(buf, p.code, (vim.uv.hrtime() - st.t) / 1e9, ev.data.cursor[1])
				started[buf] = nil
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = augroup,
		callback = function(ev)
			started[ev.buf] = nil
		end,
	})
	-- Очистить last_done когда терминал становится видимым
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = augroup,
		callback = function(ev)
			if M.last_done and M.last_done.buf == ev.buf then
				M.last_done = nil
				vim.cmd.redrawtabline()
			end
		end,
	})
end

return M
