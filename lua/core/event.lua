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
	group = vim.api.nvim_create_augroup("QClose", { clear = true }),
	pattern = {
		"qf",
		"help",
		"man",
		"notify",
		"nofile",
		"terminal",
		"prompt",
		"toggleterm",
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
-- Go module/stdlib files (pkg/mod, GOROOT): gopls attaches for goto-def/hover,
-- but has NO package metadata there — inlayHint requests fail loudly.
-- (Implementation lives in modules.utils so keymap/go extras can share it.)
local is_go_lib = require("modules.utils").is_go_lib
vim.api.nvim_create_autocmd("LspAttach", {
	group = vim.api.nvim_create_augroup("LspKeymapLoader", { clear = true }),
	callback = function(event)
		if not _G._debugging then
			-- Не-file буферы (diffview://...): скипаем всё, см. keymap.completion
			if not require("modules.utils").is_file_buffer(event.buf) then
				return
			end
			-- Skip large files
			if vim.b[event.buf].large_file then
				pcall(vim.lsp.buf_detach_client, event.buf, event.data.client_id)
				return
			end
			-- LSP Keymaps
			mapping.lsp(event.buf)

			local client = vim.lsp.get_client_by_id(event.data.client_id)

			-- Дополнение отдано nvim-cmp: встроенный autotrigger выключен,
			-- иначе два попапа дерутся.
			if client and vim.lsp.completion then
				pcall(vim.lsp.completion.enable, false, event.data.client_id, event.buf)
			end

			-- LSP Inlay Hints (skip for Go lib files: gopls answers inlayHint
			-- with "no package metadata" errors there — see is_go_lib above)
			local inlayhints_enabled = require("core.settings").lsp_inlayhints
			if client and client.server_capabilities.inlayHintProvider ~= nil then
				local fname = vim.api.nvim_buf_get_name(event.buf)
				if inlayhints_enabled == true and not is_go_lib(fname or "") then
					pcall(vim.lsp.inlay_hint.enable, true, { bufnr = event.buf })
				end
			end
		end
	end,
})

-- netrw меняет директорию через :lcd (только для окна),
-- из-за чего проводник в новом сплите снова показывает старый путь.
-- Продвигаем любую window-local смену в глобальную:
-- ментальная модель "cd меняет pwd" работает везде.
vim.api.nvim_create_autocmd("DirChanged", {
	group = vim.api.nvim_create_augroup("CdFollow", { clear = true }),
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
	group = vim.api.nvim_create_augroup("CdFollow", { clear = false }),
	pattern = "*",
	callback = function()
		local ev = vim.v.event
		if ev.scope == "global" and vim.bo.filetype == "netrw" then
			vim.cmd.edit(vim.fn.fnameescape(ev.cwd))
		end
	end,
})

require("core.large_file")
require("core.go")

-- Autojump to last edit (large files enforced first, see core.large_file).
vim.api.nvim_create_autocmd("BufReadPost", {
	group = vim.api.nvim_create_augroup("LargeFileDetectPost", { clear = true }),
	callback = function(args)
		if require("core.large_file").enforce(args.buf) then
			return
		end
		local mark = vim.api.nvim_buf_get_mark(args.buf, '"')
		local lcount = vim.api.nvim_buf_line_count(args.buf)
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
	-- PERF_DEFER: 6 vimscript cursorline-строк → 2 Lua-колбэка с ранним return.
	-- Только под флагом (без флага — старые строки 1-в-1, откат одним флагом).
	-- FocusGained/VimResized/VimLeave и строитель — не трогаем.
	local defer_on = pcall(require, "core.perf") and require("core.perf").defer_on()
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
			{ "BufWritePre", "/tmp/*,$TMPDIR/*,$TMP/*,$TEMP/*", "setlocal noundofile" },
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
				[[if ! &cursorline && ! &pvw | setlocal cursorline | endif]],
			},
			{
				"WinLeave,BufLeave,InsertEnter",
				"*",
				[[if &cursorline && ! &pvw | setlocal nocursorline | endif]],
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

	if defer_on then
		-- Выкидываем из wins обе vimscript cursorline-записи по содержимому
		-- (устойчиво к user.event-расширениям); остальное (VimLeave/
		-- FocusGained/VimResized + пользовательское) строитель создаёт как было.
		local kept = {}
		for _, def in ipairs(definitions.wins) do
			local cmd = def[3] or ""
			if not cmd:match("cursorline") then
				kept[#kept + 1] = def
			end
		end
		definitions.wins = kept
	end
	autocmd.nvim_create_augroups(require("modules.utils").extend_config(definitions, "user.event"))
	if defer_on then
		-- 2 Lua-колбэка вместо 6 vimscript-строк, в ту же группу _wins
		-- (строитель уже создал её; :autocmd _wins показывает 2 Lua + 3 редкие).
		local wins_grp = vim.api.nvim_create_augroup("_wins", { clear = false })
		vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "InsertLeave" }, {
			group = wins_grp,
			pattern = "*",
			desc = "turbo: cursorline on in focused window",
			callback = function()
				if vim.wo.cursorline then
					return
				end
				if vim.wo.previewwindow then
					return
				end
				vim.wo.cursorline = true
			end,
		})
		vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave", "InsertEnter" }, {
			group = wins_grp,
			pattern = "*",
			desc = "turbo: cursorline off outside focused window",
			callback = function()
				if not vim.wo.cursorline then
					return
				end
				if vim.wo.previewwindow then
					return
				end
				vim.wo.cursorline = false
			end,
		})
	end
end

autocmd.load_autocmds()
