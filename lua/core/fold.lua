-- core.fold — текст свёрнутого блока: первая строка с подсветкой treesitter и «··· N lines».
--
-- Почему свой: foldtext="" (0.10+) подсвечивает строку, но не говорит, сколько спрятано;
-- vim.treesitter.foldtext, который делал это, в 0.12 убран. Работает только на видимых
-- свёртках при перерисовке: одна строка, один iter_captures по уже готовому дереву.

local M = {}

--- Группа подсветки на каждый байт строки row (0-based): последний захват выигрывает,
--- как у highlighter. Без парсера/дерева/запроса — пустая таблица (строка без цвета).
local function captures(buf, row, len)
	local hl = {}
	local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
	if not ok or not parser then
		return hl
	end
	-- Дерево не парсим заново: свёртки рисуются после highlighter, дерево уже есть.
	local tree = parser:trees()[1]
	local query = tree and vim.treesitter.query.get(parser:lang(), "highlights")
	if not query then
		return hl
	end
	for id, node in query:iter_captures(tree:root(), buf, row, row + 1) do
		local name = query.captures[id]
		if not name:find("^_") then
			local sr, sc, er, ec = node:range()
			local from = sr < row and 0 or sc
			local to = er > row and len or ec
			for col = from, to - 1 do
				hl[col] = "@" .. name .. "." .. parser:lang()
			end
		end
	end
	return hl
end

--- 'foldtext': список чанков { текст, группа }.
function M.text()
	local buf, s, e = vim.api.nvim_get_current_buf(), vim.v.foldstart, vim.v.foldend
	local line = vim.api.nvim_buf_get_lines(buf, s - 1, s, false)[1] or ""
	local hl = captures(buf, s - 1, #line)
	local tab = string.rep(" ", vim.bo[buf].tabstop)
	local chunks, start = {}, 0
	for col = 1, #line do
		if col == #line or hl[col] ~= hl[start] then
			chunks[#chunks + 1] = { line:sub(start + 1, col):gsub("\t", tab), hl[start] or "Folded" }
			start = col
		end
	end
	chunks[#chunks + 1] = { "  ··· " .. (e - s + 1) .. " lines ", "Comment" }
	return chunks
end

return M
