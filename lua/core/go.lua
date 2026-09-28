-- Go extras: async organize-imports + format on save, module-cache readonly guards.
local is_go_lib = require("modules.utils").is_go_lib
-- Organize Go imports + format on save (separate from augroups due to function callback)
--
-- Полностью асинхронно: сейв НИКОГДА не блокируется.
-- BufWritePre пуст — пишем как есть; всё доделывается в BufWritePost:
-- organize-запрос → guard → применить → тихий допис → format-запрос
-- → guard → применить → тихий допис.
-- Каждый шаг сверяет changedtick (не наложить старые правки на новый
-- текст), пишем через `noautocmd update` (только при изменениях, без петель),
-- нотифаем только ошибки/пропуски.
local function go_apply_code_actions(bufnr, responses, enc)
	for _, res in pairs(responses or {}) do
		for _, action in ipairs(res.result or {}) do
			if action.edit then
				pcall(vim.lsp.util.apply_workspace_edit, action.edit, enc)
			elseif action.command then
				pcall(vim.lsp.buf.execute_command, action.command)
			end
		end
	end
end

local function go_client(bufnr)
	local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/codeAction" })
	for _, c in ipairs(clients) do
		if c.name == "gopls" then
			return c
		end
	end
	return clients[1]
end

-- Троттлинг skip-варнингов: при спаме сейвов с печатью каждая
-- цепочка скипалась бы со своим нотифаем. Чаще раза в 3с не пищим.
local last_skip_notify = 0
local function go_skip_notify(what)
	local now = vim.uv.hrtime()
	if now - last_skip_notify < 3000000000 then
		return
	end
	last_skip_notify = now
	vim.notify(
		"[go] buffer changed meanwhile, skip async " .. what .. " (run :Format)",
		vim.log.levels.WARN,
		{ title = "lsp" }
	)
end

-- Coalesce rapid saves.
--
-- Without this, every single :write fires a fresh `source.organizeImports` at
-- gopls. Three quick saves queue three module-index rebuilds, and whatever the
-- user presses next (gd especially) waits behind all of them - that queueing is
-- the multi-second freeze reported on external packages.
--
-- Module-level on purpose: a flag declared inside the autocmd closure is
-- re-created on every save, so the guard would be dead code. This is the same
-- trap as the lib_searching flag in keymap/pick.lua.
local organize_busy = {}
local organize_rerun = {}

local function go_save_pipeline(bufnr)
	if vim.b[bufnr].large_file then return end
	if organize_busy[bufnr] then
		-- One is already in flight; remember that the world moved on and do a
		-- single catch-up run when it finishes, instead of stacking a new one.
		organize_rerun[bufnr] = true
		return
	end
	local client = go_client(bufnr)
		if not client or client:is_stopped() then
			return
		end
		local enc = client.offset_encoding or "utf-16"
		local tick = vim.api.nvim_buf_get_changedtick(bufnr)
		local function guarded(what, fn)
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
				go_skip_notify(what)
				return
			end
			fn()
			tick = vim.api.nvim_buf_get_changedtick(bufnr)
		end
		organize_busy[bufnr] = true
		local params = vim.lsp.util.make_range_params(0, enc)
		params.context = { only = { "source.organizeImports" } }
		client.request("textDocument/codeAction", params, function(err, result)
			if err then
				organize_busy[bufnr] = nil
				vim.notify(
					"[go] async organize failed: " .. (err.message or "?"),
					vim.log.levels.ERROR,
					{ title = "lsp" }
				)
				return
			end
			guarded("organize", function()
				go_apply_code_actions(bufnr, { { result = result } }, enc)
				vim.cmd("noautocmd silent! update")
			end)
			tick = vim.api.nvim_buf_get_changedtick(bufnr)
			local fparams = vim.lsp.util.make_formatting_params()
			client.request("textDocument/formatting", fparams, function(err2, result2)
				if err2 then
					vim.notify(
						"[go] async format failed: " .. (err2.message or "?"),
						vim.log.levels.ERROR,
						{ title = "lsp" }
					)
					return
				end
				guarded("format", function()
					if result2 then
						vim.lsp.util.apply_text_edits(result2, bufnr, enc)
						vim.cmd("noautocmd silent! update")
					end
				end)
			end, bufnr)
			organize_busy[bufnr] = nil
			if organize_rerun[bufnr] then
				organize_rerun[bufnr] = nil
				-- client.request callbacks are fast-event; vim.schedule is required.
				vim.schedule(function()
					if vim.api.nvim_buf_is_valid(bufnr) then
						go_save_pipeline(bufnr)
					end
				end)
			end
		end, bufnr)
end

vim.api.nvim_create_autocmd("BufWritePost", {
	group = vim.api.nvim_create_augroup("GoSave", { clear = true }),
	pattern = "*.go",
	callback = function()
		go_save_pipeline(vim.api.nvim_get_current_buf())
	end,
})

-- Make Go module/stdlib files readonly (prevent accidental edits)
vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
	group = vim.api.nvim_create_augroup("GoLibRO", { clear = true }),
	callback = function()
		local file = vim.api.nvim_buf_get_name(0)
		if is_go_lib(file) then
			vim.bo.modifiable = false
			vim.bo.readonly = true
			-- NOTE: НЕ ставим buftype=nofile — к таким буферам LSP
			-- не аттачится, и внутри stdlib умирают go to definition,
			-- references и hover. Только read-only + блок сейва ниже.
		end
	end,
})

-- Block saving Go module/stdlib files
vim.api.nvim_create_autocmd("BufWritePre", {
	group = vim.api.nvim_create_augroup("GoLibRO", { clear = false }),
	callback = function()
		local file = vim.api.nvim_buf_get_name(0)
		if is_go_lib(file) then
			vim.notify("Cannot save Go library files", vim.log.levels.ERROR)
			return false
		end
	end,
})
