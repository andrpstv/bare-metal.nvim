return function()
	require("modules.utils").load_plugin("telescope", {
		defaults = {
			prompt_prefix = "󰍉  ",
			selection_caret = "▍ ",
			entry_prefix = "  ",
			sorting_strategy = "ascending",
			layout_config = { prompt_position = "top", horizontal = { preview_width = 0.55 } },
			dynamic_preview_title = true, -- имя файла вместо «Grep Preview» везде
		},
	})
end
