return function()
	-- mini.pick — единственный пикер (fzf-lua удалён).
	-- Все кеймапы живут в keymap/tool.lua (<leader>f*) и keymap/completion.lua
	-- (gd/gr/gi/gy/gO через mini.extra), здесь только setup.
	-- Ноль внешних зависимостей: rg/git/fd лишь ускоряют builtin-пикеры.
	require("modules.utils").load_plugin("mini.pick", {})
end
