return function()
	local settings = require("core.settings")
	vim.cmd.colorscheme(settings.colorscheme)

	if settings.transparent_background then
		local ok, transparent = pcall(require, "transparent")
		if ok then
			-- очищаем стандартные группы
			local groups = {
				"Normal",
				"NormalNC",
				"NormalFloat",
				"FloatBorder",
				"SignColumn",
				"LineNr",
				"EndOfBuffer",
			}
			for _, group in ipairs(groups) do
				transparent.clear_prefix(group)
			end

			-- Очищаем верхнюю панель (barbar / tabs)
			transparent.clear_prefix("Buffer")
			transparent.clear_prefix("TabLine")
			transparent.clear_prefix("TabLineFill")
			transparent.clear_prefix("TabLineSel")

			-- Очищаем другие UI элементы, если есть
			transparent.clear_prefix("NeoTree")
			transparent.clear_prefix("Telescope")
			-- Dropbar прозрачность
			vim.api.nvim_set_hl(0, "DropBarBar", { bg = "NONE" })
			vim.api.nvim_set_hl(0, "DropBarMenu", { bg = "NONE" })

			vim.cmd("TransparentEnable")
		else
			vim.notify("transparent.nvim not found", vim.log.levels.WARN)
		end
	end
end
