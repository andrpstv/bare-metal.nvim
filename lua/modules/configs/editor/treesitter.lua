return vim.schedule_wrap(function()
	local use_ssh = require("core.settings").use_ssh

	-- Ярусы (B1): full < full_lines, highlight-only < lite_lines, off выше.
	-- Ручной override на буфер: vim.b.ts_tier = "full"|"lite"|"off" (:TreesitterTier).
	local settings = require("core.settings")
	local function ts_tier(bufnr)
		if vim.b[bufnr].ts_tier then
			return vim.b[bufnr].ts_tier
		end
		if vim.b[bufnr].large_file then
			return "off"
		end
		if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
			return "off"
		end
		local n = vim.api.nvim_buf_line_count(bufnr)
		if n > (settings.treesitter_lite_lines or 10000) then
			return "off"
		elseif n > (settings.treesitter_full_lines or 2000) then
			return "lite"
		end
		return "full"
	end

	-- textobjects.init() жил в plugin/*.vim допа, а лоадер при падении
	-- plugin/ использует packadd! (только rtp) — init бы не выполнился и
	-- модуль textobjects остался бы без дефолтов: наши keymaps/select/move
	-- молча игнорировались бы. Вызываем явно: родитель уже в rtp на этом этапе.
	-- Плюс сброс отравленного кэша: первая попытка require случилась ещё
	-- внутри упавшего packadd (родителя не было в rtp) и package.loaded
	-- залип в sentinel "loop or previous error" — повтор без сброса мёртв.
	package.loaded["nvim-treesitter-textobjects"] = nil
	local ok_to_init, err_to_init = pcall(function()
		require("nvim-treesitter-textobjects").init()
	end)
	if not ok_to_init then
		vim.notify("[treesitter] textobjects init failed: " .. tostring(err_to_init):sub(1, 160), vim.log.levels.WARN, { title = "treesitter" })
	end
	require("modules.utils").load_plugin("nvim-treesitter", {
		-- БЕЗ ensure_installed осознанно: плагин ставит перечисленное САМ,
		-- без спроса (configs.setup -> install.ensure_installed), мимо
		-- confirm-пайплайна — на свежих машинах это выглядело как
		-- «после предупреждения само скачивается и падает с ошибкой».
		-- Парсеры ставит только :DistroParsers/:DistroSetup (с подтверждением).
		-- auto_install=false явно: дефолт и так false, но молчание здесь
		-- слишком дорого стоит (см. выше).
		auto_install = false,
		highlight = {
			enable = true,
			disable = function(lang, bufnr)
				return ts_tier(bufnr) == "off" or vim.tbl_contains({ "gitcommit" }, lang or "")
			end,
			additional_vim_regex_highlighting = false,
		},
		textobjects = {
			select = {
				enable = true,
				lookahead = true,
				keymaps = {
					["af"] = "@function.outer",
					["if"] = "@function.inner",
					["ac"] = "@class.outer",
					["ic"] = "@class.inner",
				},
			},
			move = {
				enable = true,
				set_jumps = true,
				goto_next_start = {
					["]["] = "@function.outer",
					["]m"] = "@class.outer",
				},
				goto_next_end = {
					["]]"] = "@function.outer",
					["]M"] = "@class.outer",
				},
				goto_previous_start = {
					["[["] = "@function.outer",
					["[m"] = "@class.outer",
				},
				goto_previous_end = {
					["[]"] = "@function.outer",
					["[M"] = "@class.outer",
				},
			},
		},
		indent = {
			enable = true,
			disable = function(_, bufnr)
				return settings.treesitter_indent == false or ts_tier(bufnr) ~= "full"
			end,
		},
	}, false, require("nvim-treesitter.configs").setup)
	-- Folds: встроенный vim.treesitter.foldexpr() (рантайм 0.10+, всегда доступен —
	-- E121 невозможен по построению). Старый nvim_treesitter#foldexpr() из пина
	-- 09-2024 на 0.12 — катастрофа: вход в proxy.go (181 строка) 60мс + 25МБ
	-- мусора на свитч, client.go (1104 строки) до 3с (замерено 2026-09-30,
	-- тикет Ctrl-O). Встроенный: 0мс на обоих, память плоская.
	vim.api.nvim_set_option_value("foldmethod", "expr", {})
	vim.api.nvim_set_option_value("foldexpr", "v:lua.vim.treesitter.foldexpr()", {})
	-- Lite/off: фолды вручную (expr на 10k+ строк — слайд-шоу на слабом ПК).
	-- Плюс всегда manual на внешних либах (go/pkg/mod, GOROOT): только чтение,
	-- сворачивать там нечего, а expr-foldexpr на ~1k строк жрёт секунды
	-- (замерено: gd в mongo client.go 4.3с -> 1с; остаток — прогрев gopls).
	-- BufWinEnter тоже: :b/C-O в уже открытый буфер не шлёт BufReadPost,
	-- и окно оставалось на expr с пересчётом на каждый вход (90мс–3с).
	vim.api.nvim_create_autocmd({ "FileType", "BufReadPost", "BufWinEnter" }, {
		group = vim.api.nvim_create_augroup("TreesitterTierFolds", { clear = true }),
		callback = function(args)
			if ts_tier(args.buf) ~= "full" then
				for _, w in ipairs(vim.api.nvim_list_wins()) do
					if vim.api.nvim_win_get_buf(w) == args.buf then
						pcall(function()
							vim.wo[w].foldmethod = "manual"
						end)
					end
				end
				return
			end
		local ok_u, utils = pcall(require, "modules.utils")
		local fname = vim.api.nvim_buf_get_name(args.buf)
		local is_lib = ok_u and utils.is_go_lib and utils.is_go_lib(fname)
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(w) == args.buf then
				pcall(function()
					if is_lib then
						vim.wo[w].foldmethod = "manual"
					else
						-- full-tier, свой файл: встроенный expr (быстрый).
						-- Чинит окна, отравленные старым foldexpr плагина.
						vim.wo[w].foldmethod = "expr"
						vim.wo[w].foldexpr = "v:lua.vim.treesitter.foldexpr()"
					end
				end)
			end
		end
		end,
		desc = "treesitter: manual folds outside full tier",
	})
	vim.api.nvim_create_user_command("TreesitterTier", function()
		local bufnr = vim.api.nvim_get_current_buf()
		local cur = vim.b[bufnr].ts_tier
			or (function()
				local n = vim.api.nvim_buf_line_count(bufnr)
				if n > (settings.treesitter_lite_lines or 10000) then
					return "off"
				elseif n > (settings.treesitter_full_lines or 2000) then
					return "lite"
				end
				return "full"
			end)()
		local next_tier = cur == "full" and "lite" or (cur == "lite" and "off" or "full")
		vim.b[bufnr].ts_tier = next_tier
		vim.notify("Treesitter tier: " .. cur .. " → " .. next_tier .. " (reopen buffer to apply)", vim.log.levels.INFO, { title = "treesitter" })
	end, { desc = "treesitter: cycle full/lite/off tier for this buffer" })
	require("nvim-treesitter.install").prefer_git = true
	if use_ssh then
		local parsers = require("nvim-treesitter.parsers").get_parser_configs()
		for _, parser in pairs(parsers) do
			parser.install_info.url = parser.install_info.url:gsub("https://github.com/", "git@github.com:")
		end
	end
end)
