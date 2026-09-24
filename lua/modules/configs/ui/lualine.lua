return function()
	-- replaces the builtin statusline when loaded (see keymap/helpers.lua)
	require("modules.utils").load_plugin("lualine", {
		options = { theme = "auto", globalstatus = true },
	})
end
