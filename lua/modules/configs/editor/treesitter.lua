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

	require("modules.utils").load_plugin("nvim-treesitter", {
		ensure_installed = require("core.settings").treesitter_deps,
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
				return ts_tier(bufnr) ~= "full"
			end,
		},
	}, false, require("nvim-treesitter.configs").setup)
	-- Folds — СТРОГО после load_plugin: foldexpr ссылается на функцию плагина,
	-- раньше — E121 на `zx` (окно между paint и загрузкой теперь секунды, не мс).
	vim.api.nvim_set_option_value("foldmethod", "expr", {})
	vim.api.nvim_set_option_value("foldexpr", "nvim_treesitter#foldexpr()", {})
	-- Lite/off: фолды вручную (expr на 10k+ строк — слайд-шоу на слабом ПК).
	vim.api.nvim_create_autocmd({ "FileType", "BufReadPost" }, {
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
