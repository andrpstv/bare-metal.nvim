return function()
	require("modules.utils").load_plugin("sidekick", {
		-- NES — подсказки Copilot LSP, которого в дистрибутиве нет; выключено, модуль не грузится.
		nes = { enabled = false },
		cli = {
			-- Перезагрузку внешних правок и политику конфликтов держит core.external: второй вотчер не нужен.
			watch = false,
			win = {
				-- Доля экрана вместо фиксированных 80 колонок: на ноутбуке окно закрывало код.
				split = { width = 0.4 },
				keys = {
					-- Пикеры требуют snacks/telescope/fzf-lua, которых нет по умолчанию; у агентов свой @-комплит.
					files = false,
					buffers = false,
				},
			},
		},
	})
end
