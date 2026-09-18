return function()
	local icons = {
		kind = require("modules.utils.icons").get("kind"),
		type = require("modules.utils.icons").get("type"),
		cmp = require("modules.utils.icons").get("cmp"),
	}

	-- Кэшируем все иконки один раз
	local lspkind_icons = vim.tbl_deep_extend("force", icons.kind, icons.type, icons.cmp)

	local border = function(hl)
		return {
			{ "┌", hl }, { "─", hl }, { "┐", hl },
			{ "│", hl }, { "┘", hl }, { "─", hl },
			{ "└", hl }, { "│", hl },
		}
	end

	-- Минимальные comparators для быстрого скролла
	local compare = require("cmp.config.compare")
	local comparators = {
		compare.offset,
		compare.exact,
		compare.sort_text,
		compare.score,
		compare.order,
	}

	local cmp = require("cmp")
	require("modules.utils").load_plugin("cmp", {
		preselect = cmp.PreselectMode.None,
		window = {
			completion = {
				border = border("PmenuBorder"),
				winhighlight = "Normal:Pmenu,CursorLine:PmenuSel,Search:PmenuSel",
				scrollbar = false,
			},
			documentation = {
				border = border("CmpDocBorder"),
				winhighlight = "Normal:CmpDoc",
			},
		},
		sorting = {
			priority_weight = 2,
			comparators = comparators,
		},
		formatting = {
			fields = { "abbr", "kind", "menu" },
			format = function(entry, vim_item)
				vim_item.kind = string.format(" %s  %s", lspkind_icons[vim_item.kind] or icons.cmp.undefined, vim_item.kind or "")

			vim_item.menu = setmetatable({
				buffer = "[BUF]",
				nvim_lsp = "[LSP]",
				path = "[PATH]",
				luasnip = "[SNIP]",
			}, { __index = function() return "[BTN]" end })[entry.source.name]

				-- Ограничиваем длину текста для ускорения рендера
				local label = vim_item.abbr
				if #label > 80 then
					vim_item.abbr = vim.fn.strcharpart(label, 0, 80) .. "..."
				end

				-- deduplicate nvim_lsp
				if entry.source.name == "nvim_lsp" then vim_item.dup = 0 end

				return vim_item
			end,
		},
		performance = {
			async_budget = 2,
			max_view_entries = 80, -- меньше элементов для рендера
		},
		mapping = cmp.mapping.preset.insert({
			["<C-p>"] = cmp.mapping.select_prev_item({ behavior = cmp.SelectBehavior.Select }),
			["<C-n>"] = cmp.mapping.select_next_item({ behavior = cmp.SelectBehavior.Select }),
			["<C-d>"] = cmp.mapping.scroll_docs(-4),
			["<C-f>"] = cmp.mapping.scroll_docs(4),
			["<C-w>"] = cmp.mapping.abort(),
			["<Tab>"] = cmp.mapping(function(fallback)
				if cmp.visible() then cmp.select_next_item({ behavior = cmp.SelectBehavior.Select })
				elseif require("luasnip").expand_or_locally_jumpable() then require("luasnip").expand_or_jump()
				else fallback() end
			end, { "i", "s" }),
			["<S-Tab>"] = cmp.mapping(function(fallback)
				if cmp.visible() then cmp.select_prev_item({ behavior = cmp.SelectBehavior.Select })
				elseif require("luasnip").jumpable(-1) then require("luasnip").jump(-1)
				else fallback() end
			end, { "i", "s" }),
			["<CR>"] = cmp.mapping({
				i = function(fallback) if cmp.visible() and cmp.get_active_entry() then cmp.confirm({ behavior = cmp.ConfirmBehavior.Insert, select = false }) else fallback() end end,
				s = cmp.mapping.confirm({ select = true }),
				c = cmp.mapping.confirm({ behavior = cmp.ConfirmBehavior.Insert, select = true }),
			}),
		}),
		snippet = { expand = function(args) require("luasnip").lsp_expand(args.body) end },
		sources = {
			{ name = "nvim_lsp", max_item_count = 100 },
			{ name = "luasnip" },
			{ name = "path" },
			{ name = "buffer", option = { get_bufnrs = function()
				local bufnrs = {}
				for _, b in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_line_count(b) < 5000 then
						table.insert(bufnrs, b)
					end
				end
				return bufnrs
			end } },
		},
		experimental = { ghost_text = false }, -- отключаем для быстрого скролла
	})

	-- Командная строка: / и : через cmp (нужен cmp-cmdline)
	cmp.setup.cmdline({ "/", "?" }, {
		mapping = cmp.mapping.preset.cmdline(),
		sources = { { name = "buffer" } },
	})
	cmp.setup.cmdline(":", {
		mapping = cmp.mapping.preset.cmdline(),
		sources = cmp.config.sources({ { name = "path" } }, { { name = "cmdline" } }),
	})
end
