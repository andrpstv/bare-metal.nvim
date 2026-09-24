return function()
	require("modules.utils").load_plugin("toggleterm", {
		open_mapping = false, -- use :ToggleTerm / your own mapping
		direction = "float",
	})
end
