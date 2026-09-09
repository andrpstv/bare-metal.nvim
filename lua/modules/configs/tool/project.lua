return function()
	require("modules.utils").load_plugin("project", {
		manual_mode = true, -- отключаем автосмену pwd
		detection_methods = { "pattern" }, -- root ищем только по паттернам, не по LSP
		patterns = { "build.gradle.kts" }, -- ищем build.gradle.kts для определения root
		lsp = { ignore = { "none-ls", "copilot" } },
		exclude_dirs = {},
		show_hidden = false,
		silent_chdir = true, -- уведомления о смене директории не показывать
		scope_chdir = "global", -- не важно, теперь manual_mode=true, смены не будет
		history = {
			save_dir = vim.fn.stdpath("data"),
		},
	})
end
