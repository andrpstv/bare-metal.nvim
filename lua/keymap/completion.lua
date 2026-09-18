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
---@param kind "supertypes"|"subtypes"
local function type_hierarchy(kind)
	local bufnr = vim.api.nvim_get_current_buf()
	local params = vim.lsp.util.make_position_params(0, "utf-16")
	local prepared = vim.lsp.buf_request_sync(bufnr, "textDocument/prepareTypeHierarchy", params, 2000)
	if not prepared then
		vim.notify("[lsp] no type hierarchy here", vim.log.levels.INFO, { title = "lsp" })
		return
	end
	local items = {}
	for _, res in pairs(prepared) do
		for _, item in ipairs(res.result or {}) do
			local resolved = vim.lsp.buf_request_sync(bufnr, "typeHierarchy/" .. kind, { item = item }, 2000)
			for _, res2 in pairs(resolved or {}) do
				for _, hi in ipairs(res2.result or {}) do
					local loc = { uri = hi.uri, range = hi.selectionRange or hi.range }
					vim.list_extend(items, vim.lsp.util.locations_to_items({ loc }, "utf-16"))
				end
			end
		end
	end
	if #items == 0 then
		vim.notify("[lsp] empty " .. kind, vim.log.levels.INFO, { title = "lsp" })
		return
	end
	vim.fn.setqflist({}, " ", { title = "LSP " .. kind, items = items })
	vim.cmd("copen")
end

---@param buf integer
function M.lsp(buf)
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
			vim.lsp.buf.signature_help()
		end):with_desc("lsp: Signature help"),
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
			:with_desc("lsp: Toggle virtual lines"),
		["n|<leader>lh"] = map_callback(function()
				_toggle_inlayhint()
			end)
			:with_noremap()
			:with_silent()
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
	local codelens_group = vim.api.nvim_create_augroup("LspCodelensRefresh", { clear = false })
	vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "BufWritePost" }, {
		group = codelens_group,
		buffer = buf,
		callback = function()
			pcall(vim.lsp.codelens.refresh)
		end,
	})

	local ok, user_mappings = pcall(require, "user.keymap.completion")
	if ok and type(user_mappings.lsp) == "function" then
		require("modules.utils.keymap").replace(user_mappings.lsp(buf))
	end
end

return M
