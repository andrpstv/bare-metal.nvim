local bind = require("keymap.bind")
local map_cr = bind.map_cr
local map_callback = bind.map_callback

local mappings = {
	fmt = {
		["n|<leader>fm"] = map_cr("Format"):with_noremap():with_silent():with_desc("formatter: Format buffer"),
		["n|<leader>ft"] = map_cr("FormatToggle"):with_noremap():with_silent():with_desc("formatter: Toggle format on save"),
	},
}
bind.nvim_load_mapping(mappings.fmt)

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
	local map = {
		-- LSP-related keymaps, ONLY effective in buffers with LSP(s) attached.
		-- Без префикс-конфликтов: ни один маппинг не является началом другого,
		-- поэтому всё срабатывает мгновенно, без ожидания timeoutlen.
		-- Встроенные дефолты grr/gri/gra удаляем ниже (дублируют gr/gi/ga).
		["n|<leader>li"] = map_cr("LspInfo"):with_silent():with_buffer(buf):with_desc("lsp: Info"),
		["n|<leader>lr"] = map_cr("LspRestart"):with_silent():with_buffer(buf):with_nowait():with_desc("lsp: Restart"),
		["n|gO"] = map_callback(function()
				_fzf("lsp_document_symbols")
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Document symbols"),
		["n|g["] = map_callback(function()
				vim.diagnostic.jump({ count = -1, float = true })
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Prev diagnostic"),
		["n|g]"] = map_callback(function()
				vim.diagnostic.jump({ count = 1, float = true })
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Next diagnostic"),
		["n|<leader>lx"] = map_callback(function()
				vim.diagnostic.open_float()
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Line diagnostic"),
		["n|gs"] = map_callback(function()
			require("completion.signature").show_smart()
		end)
			:with_silent()
			:with_noremap()
			:with_buffer(buf)
			:with_desc("lsp: Signature help (snap to call if in string)"),
		["n|gr"] = map_callback(function()
				_fzf("lsp_references")
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: References (fzf)"),
		["n|gR"] = map_callback(function()
				vim.lsp.buf.references()
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: References to quickfix"),
		["n|K"] = map_callback(function()
				vim.lsp.buf.hover()
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Show doc"),
		["nv|ga"] = map_callback(function()
				vim.lsp.buf.code_action()
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Code action (vim.ui.select)"),
		["n|gd"] = map_callback(function()
				_fzf("lsp_definitions", { jump1 = true })
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Goto definition"),
		["n|<leader>rn"] = map_callback(function()
				vim.lsp.buf.rename()
			end)
			:with_silent()
			:with_nowait()
			:with_buffer(buf)
			:with_desc("lsp: Rename"),
		["n|gi"] = map_callback(function()
				_fzf("lsp_implementations")
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Implementations (fzf)"),
		["n|gI"] = map_callback(function()
				vim.lsp.buf.implementation()
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Implementations to quickfix"),
		["n|gy"] = map_callback(function()
				_fzf("lsp_typedefs", { jump1 = true })
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Type definition (e.g. return struct)"),
		["n|gw"] = map_callback(function()
				type_hierarchy("supertypes")
			end)
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Supertypes (interfaces it implements)"),
		["n|<leader>lv"] = map_callback(function()
				_toggle_virtuallines()
			end)
			:with_noremap()
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Toggle virtual lines"),
		["n|<leader>lh"] = map_callback(function()
				_toggle_inlayhint()
			end)
			:with_noremap()
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Toggle inlay hints"),
		["n|<leader>cl"] = map_callback(function()
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
			end)
			:with_noremap()
			:with_silent()
			:with_buffer(buf)
			:with_desc("lsp: Run codelens at cursor (test/generate)"),
	}
	bind.nvim_load_mapping(map)

	-- NOTE: встроенные дефолты grr/gri/gra/grt сносятся глобально
	-- в keymap/init.lua (там же grn). Здесь чистить нечего.

	-- Codelens gopls (run test, generate, tidy...): обновляем тихо,
	-- показываются виртуал-текстом над функциями.
	-- Гард от дублей на :LspRestart (каждый LspAttach звал бы setup заново).
	if not vim.b[buf].codelens_setup then
		vim.b[buf].codelens_setup = true
		local codelens_group = vim.api.nvim_create_augroup("LspCodelensRefresh", { clear = false })
		vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "BufWritePost" }, {
			group = codelens_group,
			buffer = buf,
			callback = function()
				pcall(vim.lsp.codelens.refresh)
			end,
		})
	end

	local ok, user_mappings = pcall(require, "user.keymap.completion")
	if ok and type(user_mappings.lsp) == "function" then
		require("modules.utils.keymap").replace(user_mappings.lsp(buf))
	end
end

return M
