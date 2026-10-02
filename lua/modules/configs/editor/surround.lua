return function()
	-- nvim-surround: дефолтные клавиши upstream (ys/ds/cs + visual S),
	-- ничего кастомного — мышечная память из доки плагина работает 1:1.
	-- keymaps user-переопределяются через lua/user/keymap при желании.
	require("modules.utils").load_plugin("nvim-surround", {})
end
