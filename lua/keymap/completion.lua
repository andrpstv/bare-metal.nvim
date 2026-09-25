local map = vim.keymap.set

map("n", "<leader>fm", ":Format<CR>", { noremap = true, silent = true, desc = "formatter: Format buffer" })
map("n", "<leader>ft", ":FormatToggle<CR>", { noremap = true, silent = true, desc = "formatter: Toggle format on save" })

--- The following code allows this file to be exported ---
---    for use with LSP lazy-loaded keymap bindings    ---

local M = {}

---Иерархия типов gopls (supertypes/subtypes) в quickfix.
---supertypes структуры = интерфейсы, что она имплементит.
---Асинхронно: buf_request_sync фризил UI до 4с при висящем gopls.
---@param kind "supertypes"|"subtypes"
local function type_hierarchy(kind)
	local bufnr = vim.api.nvim_get_current_buf()
	local params = vim.lsp.util.make_position_params(0, "utf-16")
	vim.lsp.buf_request(bufnr, "textDocument/prepareTypeHierarchy", params, function(err, result)
		if err or not result or vim.tbl_isempty(result) then
			vim.notify("[lsp] no type hierarchy here", vim.log.levels.INFO, { title = "lsp" })
			return
		end
		local pending = 0
		local items = {}
		local done = function()
			pending = pending - 1
			if pending == 0 then
				if #items == 0 then
					vim.notify("[lsp] empty " .. kind, vim.log.levels.INFO, { title = "lsp" })
					return
				end
				vim.fn.setqflist({}, " ", { title = "LSP " .. kind, items = items })
				vim.cmd("copen")
			end
		end
		for _, item in ipairs(result) do
			pending = pending + 1
			vim.lsp.buf_request(bufnr, "typeHierarchy/" .. kind, { item = item }, function(err2, res2)
				if not err2 and res2 then
					for _, hi in ipairs(res2) do
						local loc = { uri = hi.uri, range = hi.selectionRange or hi.range }
						vim.list_extend(items, vim.lsp.util.locations_to_items({ loc }, "utf-16"))
					end
				end
				done()
			end)
		end
	end)
end

---@param buf integer
function M.lsp(buf)
	-- Плагинные буферы (diffview://, fugitive://, ...): у gopls от
	-- не-file URI падает JSON RPC -32700, поэтому не вешаем сюда
	-- ни кеймапы, ни codelens, ни completion (это и были источники ошибок;
	-- чистый аттач молчит — проверено).
	-- NOTE: detach НЕ делаем — vim.lsp.buf_detach_client падает с E5113
	-- на таких буферах (баг core _changetracking). Клиент висит idle.
	if not require("modules.utils").is_file_buffer(buf) then
		-- Плюс сносим встроенный K-ховер дефолта (тоже слал бы запросы).
		pcall(vim.keymap.del, "n", "K", { buffer = buf })
		return
	end
	-- LSP-related keymaps, ONLY effective in buffers with LSP(s) attached.
	-- Без префикс-конфликтов: ни один маппинг не является началом другого,
	-- поэтому всё срабатывает мгновенно, без ожидания timeoutlen.
	-- Встроенные дефолты grr/gri/gra удаляем глобально в keymap/init.lua.
	map("n", "<leader>li", ":LspInfo<CR>", { buffer = buf, silent = true, desc = "lsp: Info" })
	map(
		"n",
		"<leader>lr",
		":LspRestart<CR>",
		{ buffer = buf, silent = true, nowait = true, desc = "lsp: Restart" }
	)
	map("n", "gO", function()
		_pick_lsp("document_symbol")
	end, { buffer = buf, silent = true, desc = "lsp: Document symbols" })
	map("n", "g[", function()
		vim.diagnostic.jump({ count = -1, float = true })
	end, { buffer = buf, silent = true, desc = "lsp: Prev diagnostic" })
	map("n", "g]", function()
		vim.diagnostic.jump({ count = 1, float = true })
	end, { buffer = buf, silent = true, desc = "lsp: Next diagnostic" })
	map("n", "<leader>lx", function()
		vim.diagnostic.open_float()
	end, { buffer = buf, silent = true, desc = "lsp: Line diagnostic" })
	map("n", "gs", function()
		require("completion.signature").show_smart()
	end, {
		buffer = buf,
		silent = true,
		noremap = true,
		desc = "lsp: Signature help (snap to call if in string)",
	})
	map("n", "gr", function()
		_pick_lsp("references")
	end, { buffer = buf, silent = true, desc = "lsp: References (pick)" })
	map("n", "gR", function()
		vim.lsp.buf.references()
	end, { buffer = buf, silent = true, desc = "lsp: References to quickfix" })
	map("n", "K", function()
		vim.lsp.buf.hover()
	end, { buffer = buf, silent = true, desc = "lsp: Show doc" })
	map({ "n", "v" }, "ga", function()
		vim.lsp.buf.code_action()
	end, { buffer = buf, silent = true, desc = "lsp: Code action (vim.ui.select)" })
	map("n", "gd", function()
		_pick_lsp("definition", { jump1 = true })
	end, { buffer = buf, silent = true, desc = "lsp: Goto definition" })
	map("n", "<leader>rn", function()
		vim.lsp.buf.rename()
	end, { buffer = buf, silent = true, nowait = true, desc = "lsp: Rename" })
	map("n", "gi", function()
		_pick_lsp("implementation")
	end, { buffer = buf, silent = true, desc = "lsp: Implementations (pick)" })
	map("n", "gI", function()
		vim.lsp.buf.implementation()
	end, { buffer = buf, silent = true, desc = "lsp: Implementations to quickfix" })
	map("n", "gy", function()
		_pick_lsp("type_definition", { jump1 = true })
	end, { buffer = buf, silent = true, desc = "lsp: Type definition (e.g. return struct)" })
	map("n", "gw", function()
		type_hierarchy("supertypes")
	end, { buffer = buf, silent = true, desc = "lsp: Supertypes (interfaces it implements)" })
	map("n", "<leader>lv", function()
		_toggle_virtuallines()
	end, { buffer = buf, noremap = true, silent = true, desc = "lsp: Toggle virtual lines" })
	map("n", "<leader>lh", function()
		_toggle_inlayhint()
	end, { buffer = buf, noremap = true, silent = true, desc = "lsp: Toggle inlay hints" })
	map("n", "<leader>cl", function()
		-- Линзы могли не успеть подгрузиться: рефрешим и ждём,
		-- иначе run молча ничего не делает. Курсор — на тест-функции.
		vim.lsp.codelens.refresh()
		vim.defer_fn(function()
			local lenses = vim.lsp.codelens.get(0)
			if #(lenses or {}) == 0 then
				vim.notify(
					"[lsp] no codelens here (cursor on Test func? try :GoTestFunc)",
					vim.log.levels.WARN,
					{ title = "lsp" }
				)
				return
			end
			pcall(vim.lsp.codelens.run)
		end, 500)
	end, { buffer = buf, noremap = true, silent = true, desc = "lsp: Run codelens at cursor (test/generate)" })

	-- Codelens gopls (run test, generate, tidy...): обновляем тихо,
	-- показываются виртуал-текстом над функциями.
	-- Гард от дублей на :LspRestart (каждый LspAttach звал бы setup заново).
	-- NVIM_MINIMAL=1 пропускает целиком.
	if require("core.settings").codelens_enabled ~= false and not vim.b[buf].codelens_setup then
		vim.b[buf].codelens_setup = true
		local codelens_group = vim.api.nvim_create_augroup("LspCodelensRefresh", { clear = false })
		-- Один таймер на буфер: шторм BufEnter/InsertLeave не должен слать
		-- запросы пачками на слабом ПК. Большие файлы скипаем вообще.
		local codelens_timer = vim.uv.new_timer()
		vim.api.nvim_clear_autocmds({ group = codelens_group, buffer = buf })
		vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "BufWritePost" }, {
			group = codelens_group,
			buffer = buf,
			callback = function()
				if vim.b[buf].large_file then
					return
				end
				if codelens_timer then
					codelens_timer:stop()
					codelens_timer:start(500, 0, vim.schedule_wrap(function()
						if vim.api.nvim_buf_is_valid(buf) then
							pcall(vim.lsp.codelens.refresh)
						end
					end))
				end
			end,
		})
	end

	local ok, user_mappings = pcall(require, "user.keymap.completion")
	if ok and type(user_mappings.lsp) == "function" then
		require("modules.utils.keymap").replace(user_mappings.lsp(buf))
	end
end

return M
