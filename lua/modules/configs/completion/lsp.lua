return function()
	local utils = require("modules.utils")

	vim.diagnostic.config({
		signs = true,
		underline = true,
		virtual_text = true,
		update_in_insert = false,
	})

	-- Базовые capabilities. Без nvim-cmp: встроенному
	-- vim.lsp.completion этого достаточно.
	local opts = {
		capabilities = vim.lsp.protocol.make_client_capabilities(),
	}

	-- Серверы из settings.lsp_deps. Бинарник должен быть в $PATH
	-- (go install / brew), иначе сервер молча пропускается.
	local binaries = { lua_ls = "lua-language-server", bashls = "bash-language-server" }
	for _, name in ipairs(require("core.settings").lsp_deps) do
		if vim.fn.executable(binaries[name] or name) ~= 1 then
			vim.notify(
				string.format("[lsp] binary for [%s] not found in $PATH, skipping", name),
				vim.log.levels.WARN,
				{ title = "lsp" }
			)
		else
			local ok, preset = pcall(require, "completion.servers." .. name)
			if ok and type(preset) == "table" then
				utils.register_server(name, vim.tbl_deep_extend("force", opts, preset))
			else
				utils.register_server(name, opts)
			end
		end
	end

	pcall(require, "user.configs.lsp")
end
