-- Now use `<A-o>` or `<A-1>` to go back to the `dotstutor`.
local autocmd = {}

-- Autoclose NvimTree
vim.api.nvim_create_autocmd("BufEnter", {
	group = vim.api.nvim_create_augroup("NvimTreeAutoClose", { clear = true }),
	pattern = "NvimTree_*",
	callback = function()
		local layout = vim.api.nvim_call_function("winlayout", {})
		if
			layout[1] == "leaf"
			and vim.bo[vim.api.nvim_win_get_buf(layout[2])].filetype == "NvimTree"
			and layout[3] == nil
		then
			vim.api.nvim_command([[confirm quit]])
		end
	end,
})

-- Autoclose some filetype with <q>
vim.api.nvim_create_autocmd("FileType", {
	pattern = {
		"qf",
		"help",
		"man",
		"notify",
		"nofile",
		"terminal",
		"prompt",
		"toggleterm",
		"copilot",
		"startuptime",
		"tsplayground",
	},
	callback = function(event)
		vim.bo[event.buf].buflisted = false
		vim.api.nvim_buf_set_keymap(event.buf, "n", "q", "<Cmd>close<CR>", { silent = true })
	end,
})

-- Hold off on configuring anything related to the LSP until LspAttach
local mapping = require("keymap.completion")
vim.api.nvim_create_autocmd("LspAttach", {
	group = vim.api.nvim_create_augroup("LspKeymapLoader", { clear = true }),
	callback = function(event)
		if not _G._debugging then
			-- LSP Keymaps
			mapping.lsp(event.buf)

			local client = vim.lsp.get_client_by_id(event.data.client_id)

			-- Дополнение отдано nvim-cmp: встроенный autotrigger выключен,
			-- иначе два попапа дерутся.
			if client and vim.lsp.completion then
				pcall(vim.lsp.completion.enable, false, event.data.client_id, event.buf)
			end

			-- LSP Inlay Hints
			local inlayhints_enabled = require("core.settings").lsp_inlayhints
			if client and client.server_capabilities.inlayHintProvider ~= nil then
				vim.lsp.inlay_hint.enable(inlayhints_enabled == true, { bufnr = event.buf })
			end
		end
	end,
})

-- netrw меняет директорию через :lcd (только для окна),
-- из-за чего проводник в новом сплите снова показывает старый путь.
-- Продвигаем любую window-local смену в глобальную:
-- ментальная модель "cd меняет pwd" работает везде.
vim.api.nvim_create_autocmd("DirChanged", {
	pattern = "*",
	callback = function()
		local ev = vim.v.event
		if ev.scope == "window" then
			vim.cmd.cd(vim.fn.fnameescape(ev.cwd))
		end
	end,
})

-- Открытый netrw следует за сменой глобального pwd:
-- поменял :cd — листинг переоткрылся на новом корне.
vim.api.nvim_create_autocmd("DirChanged", {
	pattern = "*",
	callback = function()
		local ev = vim.v.event
		if ev.scope == "global" and vim.bo.filetype == "netrw" then
			vim.cmd.edit(vim.fn.fnameescape(ev.cwd))
		end
	end,
})

-- Autojump to last edit
vim.api.nvim_create_autocmd("BufReadPost", {
	callback = function()
		local mark = vim.api.nvim_buf_get_mark(0, '"')
		local lcount = vim.api.nvim_buf_line_count(0)
		if mark[1] > 0 and mark[1] <= lcount then
			pcall(vim.api.nvim_win_set_cursor, 0, mark)
		end
	end,
})

function autocmd.nvim_create_augroups(definitions)
	for group_name, definition in pairs(definitions) do
		-- Prepend an underscore to avoid name clashes
		vim.api.nvim_command("augroup _" .. group_name)
		vim.api.nvim_command("autocmd!")
		for _, def in ipairs(definition) do
			local command = table.concat(vim.iter({ "autocmd", def }):flatten(math.huge):totable(), " ")
			vim.api.nvim_command(command)
		end
		vim.api.nvim_command("augroup END")
	end
end

function autocmd.load_autocmds()
	local definitions = {
		bufs = {
			-- Reload vim config automatically
			{
				"BufWritePost",
				[[$VIM_PATH/{*.vim,*.yaml,vimrc} nested source $MYVIMRC | redraw]],
			},
			-- Reload Vim script automatically if setlocal autoread
			{
				"BufWritePost,FileWritePost",
				"*.vim",
				[[nested if &l:autoread > 0 | source <afile> | echo 'source ' . bufname('%') | endif]],
			},
			{ "BufWritePre", "*~", "setlocal noundofile" },
			{ "BufWritePre", "/tmp/*", "setlocal noundofile" },
			{ "BufWritePre", "*.tmp", "setlocal noundofile" },
			{ "BufWritePre", "*.bak", "setlocal noundofile" },
			{ "BufWritePre", "MERGE_MSG", "setlocal noundofile" },
			{ "BufWritePre", "description", "setlocal noundofile" },
			{ "BufWritePre", "COMMIT_EDITMSG", "setlocal noundofile" },
			-- Auto change directory
			-- { "BufEnter", "*", "silent! lcd %:p:h" },
			-- Auto toggle fcitx5
			-- {"InsertLeave", "* :silent", "!fcitx5-remote -c"},
			-- {"BufCreate", "*", ":silent !fcitx5-remote -c"},
			-- {"BufEnter", "*", ":silent !fcitx5-remote -c "},
			-- {"BufLeave", "*", ":silent !fcitx5-remote -c "}
		},
		wins = {
			-- Highlight current line only in focused window
			{
				"WinEnter,BufEnter,InsertLeave",
				"*",
				[[if ! &cursorline && &filetype !~# '^\(dashboard\|clap_\)' && ! &pvw | setlocal cursorline | endif]],
			},
			{
				"WinLeave,BufLeave,InsertEnter",
				"*",
				[[if &cursorline && &filetype !~# '^\(dashboard\|clap_\)' && ! &pvw | setlocal nocursorline | endif]],
			},
			-- Attempt to write shada when leaving nvim
			{
				"VimLeave",
				"*",
				[[if has('nvim') | wshada | else | wviminfo! | endif]],
			},
			-- Check if a file has changed when its window is in focus, being more proactive than 'autoread'
			{ "FocusGained", "*", "checktime" },
			-- Maintain uniform window dimensions when resizing Vim windows
			{ "VimResized", "*", [[tabdo wincmd =]] },
		},
		ft = {
			{ "FileType", "*", "setlocal formatoptions-=cro" },
			{ "FileType", "alpha", "setlocal showtabline=0" },
			{ "FileType", "markdown", "setlocal wrap" },
			{ "FileType", "dap-repl", "lua require('dap.ext.autocompl').attach()" },
			{
				"FileType",
				"c,cpp",
				"nnoremap <silent> <buffer> <leader>h <Cmd>ClangdSwitchSourceHeader<CR>",
			},
		},
		yank = {
			{
				"TextYankPost",
				"*",
				[[silent! lua vim.highlight.on_yank({ higroup = 'IncSearch', timeout = 300 })]],
			},
		},
	}

	autocmd.nvim_create_augroups(require("modules.utils").extend_config(definitions, "user.event"))
end

autocmd.load_autocmds()

-- Organize Go imports + format on save (separate from augroups due to function callback)
--
-- Два пути: быстрый синхронный (тёплый gopls отвечает за ~10-50мс,
-- сейв атомарный) и фоновый (холодный gopls на большом репо:
-- сейв НЕ блокируем, доделываем асинхронно с защитой changedtick,
-- чтобы не наложить старые правки на новый текст; пишем тихо,
-- нотифаем только проблемы).
local function go_apply_code_actions(bufnr, responses, enc)
	for _, res in pairs(responses or {}) do
		for _, action in ipairs(res.result or {}) do
			if action.edit then
				vim.lsp.util.apply_workspace_edit(action.edit, enc)
			elseif action.command then
				vim.lsp.buf.execute_command(action.command)
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

vim.api.nvim_create_autocmd("BufWritePre", {
	pattern = "*.go",
	callback = function()
		local bufnr = vim.api.nvim_get_current_buf()
		local client = go_client(bufnr)
		if not client then
			return
		end
		local enc = client.offset_encoding or "utf-16"
		local params = vim.lsp.util.make_range_params(0, enc)
		params.context = { only = { "source.organizeImports" } }

		-- Быстрый путь: тёплый gopls успевает за 400мс.
		local fast = vim.lsp.buf_request_sync(bufnr, "textDocument/codeAction", params, 400)
		if fast then
			go_apply_code_actions(bufnr, fast, enc)
			vim.lsp.buf.format({ async = false })
			return
		end

		-- Медленный путь: gopls холодный — сейв отпускаем сразу,
		-- доделываем фоном. Перепроверяем tick перед КАЖДЫМ применением.
		vim.notify("[go] gopls is warming up, will organize+format in background", vim.log.levels.INFO, {
			title = "lsp",
		})
		local tick = vim.api.nvim_buf_get_changedtick(bufnr)
		local function guarded(what, fn)
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
				vim.notify(
					"[go] buffer changed meanwhile, skip async " .. what .. " (run :Format)",
					vim.log.levels.WARN,
					{ title = "lsp" }
				)
				return
			end
			fn()
			-- Новая база: наши собственные правки tick двигают,
			-- последующие шаги сверяются уже с ним, а не с сейвовым.
			tick = vim.api.nvim_buf_get_changedtick(bufnr)
		end
		vim.defer_fn(function()
			if not vim.api.nvim_buf_is_valid(bufnr) or client:is_stopped() then
				return
			end
			client.request("textDocument/codeAction", params, function(err, result)
				if err then
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
				-- Формат следом, тоже асинхронно и под тем же guard.
				-- База свежая: параметры форматирования считаем заново,
				-- поэтому сверяемся с текущим tick, а не с сейвовым.
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
			end, bufnr)
		end, 500)
	end,
})

-- Make Go module/stdlib files readonly (prevent accidental edits)
local function is_go_lib(file)
	return file:match("/go/pkg/mod/")
		or file:match("/opt/homebrew/Cellar/go/")
		or file:match("/opt/homebrew/opt/go/")
		or file:match("\\go\\pkg\\mod\\")
		or file:match("Program Files\\Go\\")
end

vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
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
	callback = function()
		local file = vim.api.nvim_buf_get_name(0)
		if is_go_lib(file) then
			vim.notify("Cannot save Go library files", vim.log.levels.ERROR)
			return false
		end
	end,
})
