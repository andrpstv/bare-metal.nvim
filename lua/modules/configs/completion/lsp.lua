return function()
	local utils = require("modules.utils")

	local settings = require("core.settings")

	-- Дефолт диагностики — из settings, а не захардкожен: diagnostics_virtual_lines
	-- переключает virtual_text/virtual_lines, diagnostics_level задаёт min severity.
	local virt_lines = settings.diagnostics_virtual_lines
	local sev_min = (vim.diagnostic.severity or {})[settings.diagnostics_level or "HINT"]
		or vim.diagnostic.severity.HINT
	vim.diagnostic.config({
		signs = { severity = { min = sev_min } },
		underline = { severity = { min = sev_min } },
		virtual_text = (not virt_lines) and { severity = { min = sev_min } } or false,
		virtual_lines = virt_lines and { only_current_line = true } or false,
		severity_sort = true,
		update_in_insert = false,
	})

	-- Capabilities: база + расширение от cmp-nvim-lsp (snippetSupport и др.),
	-- чтобы gopls присылал полные варианты.
	-- cmp грузится лениво (InsertEnter), а LSP стартует раньше (BufReadPre),
	-- поэтому тянем его явно: без этого require падает и LSP не встанет.
	-- PERF_DEFER (D): под флагом — статическая таблица (те же поля, что отдаёт
	-- cmp_nvim_lsp сегодня; сверено с servers/gopls.lua:24-44) + догрузка
	-- настоящего cmp в schedule / на первый InsertEnter. gopls читает caps
	-- один раз на initialize, уже аттачные клиенты не меняются — gd/gr святое.
	-- Без флага — старый путь 1-в-1.
	-- Статический fallback: форма повторяет cmp_nvim_lsp.default_capabilities().
	local TURBO_CMP_CAPS = {
		textDocument = {
			completion = {
				dynamicRegistration = true,
				contextSupport = true,
				completionItem = {
					snippetSupport = true,
					commitCharactersSupport = true,
					documentationFormat = { "markdown", "plaintext" },
					deprecatedSupport = true,
					preselectSupport = true,
					tagSupport = { valueSet = { 1 } },
					insertReplaceSupport = true,
					resolveSupport = {
						properties = { "documentation", "details", "additionalTextEdits" },
					},
					labelDetailsSupport = true,
				},
			},
		},
	}
	local cmp_caps = {}
	local ok_perf, perf_mod = pcall(require, "core.perf")
	local defer_on = ok_perf and perf_mod.defer_on and perf_mod.defer_on() or false
	if defer_on then
		cmp_caps = TURBO_CMP_CAPS
		-- Догрузка настоящего cmp: в schedule (не блокирует open) + страховка
		-- на первый InsertEnter каждого буфера (per-buffer флаг).
		vim.schedule(function()
			pcall(require("distro.loader").load, "nvim-cmp")
		end)
		local cmp_grp = vim.api.nvim_create_augroup("TurboCmpCaps", { clear = false })
		vim.api.nvim_create_autocmd("InsertEnter", {
			group = cmp_grp,
			desc = "turbo: warm nvim-cmp on first insert",
			callback = function(ev)
				if vim.b[ev.buf].cmp_caps_real then
					return
				end
				vim.b[ev.buf].cmp_caps_real = true
				pcall(require("distro.loader").load, "nvim-cmp")
			end,
		})
	elseif not pcall(function()
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
	-- NVIM_MINIMAL=1 выключает (см. низ core/settings.lua).
	if require("core.settings").signature_enabled ~= false then
		require("completion.signature").setup()
	end
end
