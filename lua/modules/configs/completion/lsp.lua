return function()
	local utils = require("modules.utils")

	vim.diagnostic.config({
		signs = true,
		underline = true,
		virtual_text = true,
		update_in_insert = false,
	})

	-- Capabilities: база + расширение от cmp-nvim-lsp (snippetSupport и др.),
	-- чтобы gopls присылал полные варианты.
	-- cmp грузится лениво (InsertEnter), а LSP стартует раньше (BufReadPre),
	-- поэтому тянем его явно: без этого require падает и LSP не встанет.
	local cmp_caps = {}
	if not pcall(function()
		cmp_caps = require("cmp_nvim_lsp").default_capabilities()
	end) then
		pcall(function()
			require("distro.loader").load("nvim-cmp")
			cmp_caps = require("cmp_nvim_lsp").default_capabilities()
		end)
	end
	local opts = {
		capabilities = vim.tbl_deep_extend(
			"force",
			vim.lsp.protocol.make_client_capabilities(),
			cmp_caps
		),
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
			elseif ok and type(preset) == "function" then
				-- clangd.lua возвращает function(defaults): вызывает vim.lsp.config сам.
				preset(opts)
			else
				utils.register_server(name, opts)
			end
		end
	end

	pcall(require, "user.configs.lsp")

	-- Липкая сигнатура без плагинов (своя, см. completion.signature).
	require("completion.signature").setup()
end
