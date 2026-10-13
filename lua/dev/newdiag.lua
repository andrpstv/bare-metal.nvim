-- dev.newdiag — после сохранения вспыхивают только НОВЫЕ ERROR-диагностики (не весь шум буфера).
--
-- Почему свой: ядро знает лишь DiagnosticChanged; «новое» = ключ (текст строки + сообщение), номер
-- строки не годится — вставка выше сдвигает всё. Цена: снимок на BufWritePre, дальше ровно одно сравнение.
local M = {}

local before = {} ---@type table<integer, table<string, integer>> буфер -> ключ -> сколько раз
M.pending = {} ---@type table<integer, integer> буфер -> момент BufWritePost (ждём ответа LSP)

---@param buf integer
---@return {lnum: integer, key: string}[]
local function errors(buf)
	local out = {}
	for _, d in ipairs(vim.diagnostic.get(buf, { severity = vim.diagnostic.severity.ERROR })) do
		local line = vim.api.nvim_buf_get_lines(buf, d.lnum, d.lnum + 1, false)[1] or ""
		out[#out + 1] = { lnum = d.lnum, key = line .. "\0" .. d.message }
	end
	return out
end

--- Строки (0-based, по возрастанию) ошибок, которых не было в снимке. Чистая — для тестов.
---@param snap table<string, integer>
---@param after {lnum: integer, key: string}[]
---@return integer[]
function M._new(snap, after)
	local left, rows = vim.deepcopy(snap), {}
	for _, e in ipairs(after) do
		if (left[e.key] or 0) > 0 then
			left[e.key] = left[e.key] - 1
		else
			rows[#rows + 1] = e.lnum
		end
	end
	table.sort(rows)
	return rows
end

--- BufWritePre: снимок ERROR до записи (только обычные буферы, не large_file).
function M.snapshot(buf)
	if vim.bo[buf].buftype ~= "" or vim.b[buf].large_file then
		return
	end
	local snap = {}
	for _, e in ipairs(errors(buf)) do
		snap[e.key] = (snap[e.key] or 0) + 1
	end
	before[buf] = snap
end

--- BufWritePost: ждём следующий DiagnosticChanged этого буфера.
function M.arm(buf)
	if before[buf] then
		M.pending[buf] = vim.uv.now()
	end
end

--- DiagnosticChanged: если ждали — один раз сравнить и вспыхнуть. Нет ответа за 5 с — отбой.
function M.check(buf)
	local t = M.pending[buf]
	if not t then
		return
	end
	M.pending[buf] = nil
	local snap = before[buf]
	before[buf] = nil
	if not snap or vim.uv.now() - t > 5000 or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local rows = M._new(snap, errors(buf))
	if #rows > 0 then
		-- shortcut: flash_rows держит одну вспышку на буфер, поэтому красим только первую новую; нужны все — расширить fx.flash_rows списком.
		require("dev.fx").flash_rows(buf, rows[1], rows[1])
	end
end

return M
