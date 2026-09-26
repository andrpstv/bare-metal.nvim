 	return function()
	local mapping = require("keymap.ui")

	-- TURBO (T3): под флагом auto_attach=false + отложенный attach на idle /
	-- первый BufWritePost (once per-buffer). gitsigns с auto_attach=false не
	-- ставит свои attach-автокоманды (см. setup_attach), поэтому аттачим сами
	-- через actions.attach — on_attach large_file-гард ниже всё равно работает.
	-- Headless/SYNC — синхронно как сейчас. Без флага — как сейчас 1-в-1.
	local turbo_on = pcall(require, "core.turbo") and require("core.turbo").is_on()
	local turbo_defer = turbo_on
		and #vim.api.nvim_list_uis() > 0
		and vim.env.NVIM_DISTRO_SYNC ~= "1"
	require("modules.utils").load_plugin("gitsigns", {
		signs = {
			add = { text = "┃" },
			change = { text = "┃" },
			delete = { text = "_" },
			topdelete = { text = "‾" },
			changedelete = { text = "~" },
			untracked = { text = "┆" },
		},
		auto_attach = not turbo_defer,
		-- Большие файлы не аттачим вообще: git diff + вотчеры на 10k+ строк
		-- вешают слабый ПК, а пользы ноль (там и так всё выключено).
		on_attach = function(bufnr)
			if vim.b[bufnr].large_file then
				return false
			end
			return mapping.gitsigns(bufnr)
		end,
		signcolumn = true,
		sign_priority = 6,
		update_debounce = 200,
		word_diff = false,
		current_line_blame = false,
		diff_opts = { internal = true },
		watch_gitdir = { follow_files = true, interval = 5000 },
	})
	if turbo_defer then
		local grp = vim.api.nvim_create_augroup("TurboGitsignsAttach", { clear = false })
		-- BufReadPost/InsertEnter — знаки сразу на открытии и на первом наборе
		-- (CursorHold один ждёт ~4000мс updatetime, т.е. на старте экрана пусто).
		vim.api.nvim_create_autocmd({ "BufReadPost", "InsertEnter", "CursorHold", "CursorHoldI", "InsertLeave", "BufWritePost" }, {
			group = grp,
			desc = "turbo: deferred gitsigns attach on idle/save",
			callback = function(ev)
				if vim.b[ev.buf].gitsigns_deferred then
					return
				end
				-- Сначала гарды, только потом latch: иначе отброшенный буфер
				-- (large_file / без git) помечается «сделанным» навсегда.
				if vim.b[ev.buf].large_file then
					return
				end
				if vim.fn.executable("git") ~= 1 then
					return
				end
				vim.b[ev.buf].gitsigns_deferred = true
				local bufnr = ev.buf
				vim.schedule(function()
					if not vim.api.nvim_buf_is_valid(bufnr) then
						return
					end
					pcall(function()
						require("gitsigns.actions").attach({ bufnr = bufnr, trigger = "turbo-idle" })
					end)
				end)
			end,
		})
	end
end
