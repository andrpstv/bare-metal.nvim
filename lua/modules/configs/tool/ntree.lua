return function()
	require("modules.utils").load_plugin("nvim-tree", {
		view = { width = 32 },
		update_focused_file = { enable = true },
	})
end
