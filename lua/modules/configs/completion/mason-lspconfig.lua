local M = {}

M.setup = function()
	local is_windows = require("core.global").is_windows
	local lsp_deps = require("core.settings").lsp_deps
	local mason_registry = require("mason-registry")
	local mason_lspconfig = require("mason-lspconfig")

	require("lspconfig.ui.windows").default_options.border = "rounded"
	require("modules.utils").load_plugin("mason-lspconfig", {
		ensure_installed = lsp_deps,
		automatic_enable = false,
	})

	vim.diagnostic.config({
		signs = true,
		underline = true,
		virtual_text = true,
		update_in_insert = false,
	})

	local opts = {
		capabilities = vim.tbl_deep_extend(
			"force",
			vim.lsp.protocol.make_client_capabilities(),
			require("cmp_nvim_lsp").default_capabilities()
		),
	}

	local skip_lsp = {
		rust_analyzer = true,
		kotlin_lsp = true,
		marksman = true,
		tailwindcss = true,
		pylsp = true,
		html = true,
		cssls = true,
		cssmodules_ls = true,
		emmet_language_server = true,
		graphql = true,
		prismals = true,
		biome = true,
		eslint = true,
		jsonls = true,
	}

	local function mason_lsp_handler(lsp_name)
		if skip_lsp[lsp_name] then
			return
		end

		local ok, custom_handler = pcall(require, "user.configs.lsp-servers." .. lsp_name)
		local default_ok, default_handler = pcall(require, "completion.servers." .. lsp_name)

		if not ok then
			ok, custom_handler = default_ok, default_handler
		end

		if not ok then
			require("modules.utils").register_server(lsp_name, opts)
		elseif type(custom_handler) == "function" then
			custom_handler(opts)
			vim.lsp.enable(lsp_name)
		elseif type(custom_handler) == "table" then
			require("modules.utils").register_server(
				lsp_name,
				vim.tbl_deep_extend(
					"force",
					opts,
					type(default_handler) == "table" and default_handler or {},
					custom_handler
				)
			)
		else
			vim.notify(
				string.format(
					"Failed to setup [%s]. Server must return fun(opts) или table (got '%s')",
					lsp_name,
					type(custom_handler)
				),
				vim.log.levels.ERROR,
				{ title = "nvim-lspconfig" }
			)
		end
	end

	-- Запускаем обработчик для всех установленных пакетов Mason
	local function setup_lsp_for_package(pkg)
		local mappings = mason_lspconfig.get_mappings().package_to_lspconfig
		if not mappings or vim.tbl_isempty(mappings) then
			mappings = {}
			for _, spec in ipairs(mason_registry.get_all_package_specs()) do
				local lspconfig = vim.tbl_get(spec, "neovim", "lspconfig")
				if lspconfig then
					mappings[spec.name] = lspconfig
				end
			end
		end

		local name = type(pkg) == "string" and pkg or pkg.name
		local srv = mappings[name]
		if not srv then
			return
		end

		mason_lsp_handler(srv)
	end

	for _, pkg in ipairs(mason_registry.get_installed_package_names()) do
		setup_lsp_for_package(pkg)
	end

	-- Устанавливаем hook на установку пакета через Mason
	mason_registry:on(
		"package:install:success",
		vim.schedule_wrap(function(pkg)
			setup_lsp_for_package(pkg)
		end)
	)
end

return M
