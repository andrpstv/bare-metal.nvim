return function()
	require("modules.utils").load_plugin("telescope", {
		defaults = {
			sorting_strategy = "ascending",
			layout_config = { prompt_position = "top" },
		},
	})
end
