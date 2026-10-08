return function()
	require("modules.utils").load_plugin("which-key", {
		preset = "classic",
		delay = 400, -- быстрее дефолтного: подсказка должна опережать действие
		win = { border = "rounded" },
		icons = { mappings = false }, -- без иконок: devicons и так в строке
		show_help = false, -- без лишней строки помощи: экран — под дерево
		show_keys = false,
	})
end
