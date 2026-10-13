-- dev.gcdetails — решения компилятора (codelens gopls «gc details»: escape/inline) тихим
-- текстом в конце строки: `  ↑t ↑s · inl`.
--
-- Почему свой: gopls шлёт их обычной диагностикой (INFO, source "optimizer details") —
-- знак и virtual text почти на каждой строке тонут в шуме и прячут настоящие ошибки.
-- Вырезаем их из publishDiagnostics (gopls 0.22 — только push) и рисуем сами.
-- Модуль грузится при первом publishDiagnostics от gopls (servers/gopls.lua).

local M = {}

M.SOURCE = "optimizer details"
local ns = vim.api.nvim_create_namespace("dev_gcdetails")

--- Короткая метка: `escape(t escapes to heap)` -> `↑t`, `canInlineFunction(cost: 12)` -> `inl`.
--- nil — шум (пустой escape(), «does not escape»), его не показываем.
---@param msg string
---@return string?
function M._short(msg)
	local kind, arg = msg:match("^(%w+)%((.*)%)$")
	kind, arg = kind or msg, arg or ""
	if kind == "escape" then
		local what = arg:match("^(.-) escapes to heap") or arg:match("^moved to heap: (.+)$")
		-- `&Square{...}` -> `&Square`: тип виден, литерал — шум.
		what = what and what:gsub("{%.%.%.}$", "")
		-- ~r0 и т.п. — временные компилятора, читателю кода ничего не говорят.
		if not what or what:find("^~") then
			return nil
		end
		return "↑" .. (vim.fn.strchars(what) > 20 and (vim.fn.strcharpart(what, 0, 19) .. "…") or what)
	elseif kind == "leak" then
		return "leak"
	elseif kind == "canInlineFunction" then
		return "inl"
	elseif kind == "cannotInlineFunction" then
		return "no-inl"
	elseif kind == "inlineCall" then
		return "inl " .. (arg:match("([%w_]+)$") or arg)
	end
	return kind
end

--- Диагностики одного файла -> { [lnum 0-based] = "↑t ↑s · inl" } (метки без повторов).
function M._lines(diags)
	local per, out = {}, {}
	for _, d in ipairs(diags) do
		local s = M._short(d.message or "")
		local l = d.range and d.range.start.line
		if s and l then
			per[l] = per[l] or { seen = {}, list = {} }
			if not per[l].seen[s] then
				per[l].seen[s] = true
				table.insert(per[l].list, s)
			end
		end
	end
	for l, p in pairs(per) do
		out[l] = table.concat(p.list, " · ")
	end
	return out
end

--- Обёртка над textDocument/publishDiagnostics: optimizer details -> свои метки, остальное — как было.
function M.on_publish(err, result, ctx)
	if result and result.diagnostics then
		local keep, opt = {}, {}
		for _, d in ipairs(result.diagnostics) do
			table.insert(d.source == M.SOURCE and opt or keep, d)
		end
		-- uri без схемы встречался вживую (gopls 0.22): тогда меток не рисуем, а диагностику
		-- отдаём дальше как есть — падение здесь съело бы и настоящие ошибки.
		local ok, path = pcall(vim.uri_to_fname, result.uri or "")
		-- bufnr(path) ищет по шаблону — сверяем имя точно; файл без буфера не открываем.
		local buf = ok and vim.fn.bufnr(path) or -1
		if buf > 0 and vim.api.nvim_buf_get_name(buf) == path and vim.api.nvim_buf_is_loaded(buf) then
			vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
			local n = vim.api.nvim_buf_line_count(buf)
			for l, text in pairs(M._lines(opt)) do
				if l < n then
					vim.api.nvim_buf_set_extmark(buf, ns, l, 0, {
						virt_text = { { "  " .. text, "Comment" } },
						virt_text_pos = "eol",
					})
				end
			end
		end
		if #opt > 0 then
			result = vim.tbl_extend("force", result, { diagnostics = keep })
		end
	end
	return vim.lsp.diagnostic.on_publish_diagnostics(err, result, ctx)
end

return M
