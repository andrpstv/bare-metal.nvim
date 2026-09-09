return function()
	-- Настройки Sonokai
	vim.g.sonokai_style = "shusia"
	vim.g.sonokai_transparent_background = true -- если хочешь прозрачность
	vim.g.sonokai_disable_italic_comment = false

	-- Можно настроить другие флаги, например:
	-- vim.g.sonokai_better_performance = true

	-- Применяем тему
	vim.cmd("colorscheme sonokai")
end
