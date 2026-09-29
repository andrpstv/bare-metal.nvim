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

	-- Watchdog gopls (speed-program C2b): раньше смерть сервера означала мёртвый
	-- cmp до рестарта nvim. На LspDetach проверяем в schedule: если gopls к
	-- буферу не вернулся — рестарт через :edit с бэкоффом (макс 3, дальше
	-- честная подсказка). Ручной <leader>lr ставит флаг и не триггерит.
	local wd_grp = vim.api.nvim_create_augroup("GoplsWatchdog", { clear = true })
	vim.api.nvim_create_autocmd("LspAttach", {
		group = wd_grp,
		desc = "watchdog: reset gopls restart counter",
		callback = function(args)
			vim.b[args.buf].gopls_restarts = nil
		end,
	})
	vim.api.nvim_create_autocmd("LspDetach", {
		group = wd_grp,
		desc = "watchdog: revive dead gopls",
		callback = function(args)
			local buf = args.buf
			if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "go" then
				return
			end
			if vim.b[buf].large_file or vim.b[buf].lsp_manual_restart then
				vim.b[buf].lsp_manual_restart = nil
				return
			end
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(buf) then
					return
				end
				for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
					if c.name == "gopls" then
						return
					end
				end
				local n = (vim.b[buf].gopls_restarts or 0) + 1
				vim.b[buf].gopls_restarts = n
				if n > 3 then
					vim.notify(
						"[lsp] gopls keeps dying — update it (:DistroBinaries) or check the file for syntax errors",
						vim.log.levels.ERROR,
						{ title = "lsp" }
					)
					return
				end
				vim.notify(
					"[lsp] gopls detached, restarting (" .. n .. "/3)",
					vim.log.levels.WARN,
					{ title = "lsp" }
				)
				-- NOTE: :edit сам шлёт LspDetach (0.12) — без флага рестарт
				-- зацикливается сам на себе: detach → :edit → detach → …
				-- (поймано по стеку: detach шёл из lsp.lua через vim.cmd edit).
				-- Плюс на modified-буфере :edit падает с E37 — туда не лезем.
				if vim.bo[buf].modified then
					vim.notify(
						"[lsp] buffer has unsaved changes — save it and press <leader>lr",
						vim.log.levels.WARN,
						{ title = "lsp" }
					)
					return
				end
				vim.b[buf].lsp_manual_restart = true
				vim.defer_fn(function()
					if vim.api.nvim_buf_is_valid(buf) then
						pcall(function()
							vim.api.nvim_buf_call(buf, function()
								vim.cmd("edit")
							end)
						end)
					end
				end, 1500)
			end)
		end,
	})

	-- Глобальный <leader>li: без сервера подсказывает что поставить,
	-- буферный маппинг (keymap/completion.lua) перекрывает при аттаче.
	vim.keymap.set("n", "<leader>li", function()
		if #vim.lsp.get_clients({ bufnr = 0 }) == 0 then
			vim.notify(
				"[lsp] no server here. Go: `go install golang.org/x/tools/gopls@latest`. See :DistroBinaries",
				vim.log.levels.WARN,
				{ title = "lsp" }
			)
		else
			vim.cmd("checkhealth vim.lsp")
		end
	end, { silent = true, desc = "lsp: Info / what to install" })

	-- Липкая сигнатура без плагинов (своя, см. completion.signature).
	-- NVIM_MINIMAL=1 выключает (см. низ core/settings.lua).
	if require("core.settings").signature_enabled ~= false then
		require("completion.signature").setup()
	end
end
