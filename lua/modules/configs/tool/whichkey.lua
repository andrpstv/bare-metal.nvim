-- RU-дубли (keymap/ru.lua) работают, но в подсказке удваивают список: прячем маппинги с кириллицей
-- в lhs (UTF-8 lead-байты 0xD0/0xD1). Вынесено для теста.
local function not_cyrillic(mapping)
	return not (mapping.lhs or ""):find("[\208\209]")
end

return function()
	require("modules.utils").load_plugin("which-key", {
		preset = "classic",
		delay = 400, -- быстрее дефолтного: подсказка должна опережать действие
		win = { border = "rounded" },
		icons = { mappings = false }, -- без иконок: devicons и так в строке
		show_help = false, -- без лишней строки помощи: экран — под дерево
		show_keys = false,
		filter = not_cyrillic,
		spec = {
			{ "<leader>A", group = "agent" },
			{ "<leader>a", group = "go assign / test alias" },
			{ "<leader>b", group = "buffer" },
			{ "<leader>c", group = "codelens" },
			{ "<leader>d", group = "debug" },
			{ "<leader>f", group = "find / format / fill" },
			{ "<leader>g", group = "git / go / test" },
			{ "<leader>i", group = "snippet" },
			{ "<leader>l", group = "lsp" },
			{ "<leader>p", group = "packages" },
			{ "<leader>r", group = "run / build / rename" },
			{ "<leader>s", group = "split / session / search" },
			{ "<leader>t", group = "test / terminal / tab" },
			{ "<leader>v", group = "selection" },
			{ "<leader>w", group = "project" },
		},
	})
end
