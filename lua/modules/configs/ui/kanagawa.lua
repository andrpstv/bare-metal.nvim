return function()
	require("kanagawa").setup({
		compile = false,
		undercurl = true,
		commentStyle = { italic = true },
		functionStyle = {},
		keywordStyle = { italic = true },
		statementStyle = { bold = true },
		typeStyle = {},
		transparent = false, -- если хочешь прозрачность, переключай на true
		dimInactive = false,
		terminalColors = true,

		colors = {
			theme = {
				all = {
					ui = {
						bg_gutter = "none",
					},
				},
				wave = {
					ui = {
						float = { bg = "none" },
					},
				},
				dragon = {
					-- здесь можно тонко переопределять для dragon варианта
				},
			},
		},

		overrides = function(colors)
			-- colors.palette и colors.theme доступны здесь
			return {
				-- Пример: строковые литералы красные
				String = { fg = colors.palette.winterRed, italic = true },
				-- Пример: ключевые слова (если хочешь “темный красный”)
				Keyword = { fg = colors.palette.samuraiRed, bold = true },
				-- Прозрачные окна
				NormalFloat = { bg = "none" },
				FloatBorder = { bg = "none" },
			}
		end,

		theme = "wave", -- вариант темы: “wave”, “dragon”, “lotus”
		background = {
			dark = "wave",
			light = "lotus",
		},
	})

	vim.cmd("colorscheme kanagawa")
end
