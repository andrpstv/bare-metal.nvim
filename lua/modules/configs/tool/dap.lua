-- tool.dap — loader-конфиг nvim-dap. Без load_plugin: у dap нет setup(),
-- только регистрация знаков; адаптеры/конфигурации ставит dev.debug
-- (там же delve без nvim-dap-go: 20 строк вместо плагина).
-- user.configs.dap → false скипает только знаки, сам dap остаётся грузимым.
return function()
	local ok_user, user = pcall(require, "user.configs.dap")
	if ok_user and user == false then
		return
	end
	local signs = {
		DapBreakpoint = { text = "●" },
		DapBreakpointCondition = { text = "◆" },
		DapBreakpointRejected = { text = "✖" },
		DapLogPoint = { text = "◉" },
		DapStopped = { text = "▶" },
	}
	for name, s in pairs(signs) do
		pcall(vim.fn.sign_define, name, { text = s.text, texthl = name, linehl = "", numhl = "" })
	end
	-- Float'ы виджетов (scopes/frames/hover) и REPL открываются С фокусом
	-- и без клавиши закрытия: пользователь застревает (q пишет в код,
	-- :q надо знать). Локальный q → закрыть окно: в insert REPL и в
	-- normal float'ов q больше ничего не делает, конфликтов нет.
	local group = vim.api.nvim_create_augroup("DevDapClose", { clear = true })
	for _, ft in ipairs({ "dap-repl", "dap-float" }) do
		vim.api.nvim_create_autocmd("FileType", {
			group = group,
			pattern = ft,
			desc = "debug: q closes dap float/repl window",
			callback = function(args)
				vim.keymap.set("n", "q", "<Cmd>close<CR>", {
					buffer = args.buf,
					noremap = true,
					silent = true,
					desc = "debug: close this dap window",
				})
			end,
		})
	end
end
