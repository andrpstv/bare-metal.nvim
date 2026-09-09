return function()
	local icons = {
		diagnostics = require("modules.utils.icons").get("diagnostics"),
		documents = require("modules.utils.icons").get("documents"),
		git = require("modules.utils.icons").get("git"),
		ui = require("modules.utils.icons").get("ui"),
	}

	require("modules.utils").load_plugin("neo-tree", {
		close_if_last_window = true,
		popup_border_style = "rounded",
		enable_git_status = true,
		enable_diagnostics = true,

		window = {
			position = "left",
			width = 35,
			mapping_options = { noremap = true, nowait = true },
			mappings = {
				["l"] = "open",
				["h"] = "close_node",
				["<CR>"] = "open",
			},
		},

		default_component_configs = {
			indent = {
				padding = 1,
				with_expanders = true,
				expanders = {
					collapsed = icons.ui.ArrowClosed,
					expanded = icons.ui.ArrowOpen,
				},
			},
			icon = {
				folder = {
					default = icons.ui.Folder,
					open = icons.ui.FolderOpen,
					empty = icons.ui.EmptyFolder,
					empty_open = icons.ui.EmptyFolderOpen,
					symlink = icons.ui.SymlinkFolder,
					symlink_open = icons.ui.FolderOpen,
					arrow_open = icons.ui.ArrowOpen,
					arrow_closed = icons.ui.ArrowClosed,
				},
				file = icons.documents.Default,
				symlink = icons.documents.Symlink,
				git = {
					unstaged = icons.git.Mod_alt,
					staged = icons.git.Add,
					unmerged = icons.git.Unmerged,
					renamed = icons.git.Rename,
					untracked = icons.git.Untracked,
					deleted = icons.git.Remove,
					ignored = icons.git.Ignore,
				},
			},
			name = {
				trailing_slash = false,
			},
			diagnostics = {
				hint = icons.diagnostics.Hint_alt,
				info = icons.diagnostics.Information_alt,
				warning = icons.diagnostics.Warning_alt,
				error = icons.diagnostics.Error_alt,
			},
		},

		filesystem = {
			follow_current_file = { enabled = true },
			use_libuv_file_watcher = true,
			filtered_items = {
				hide_dotfiles = false,
				visible = true,
			},
			cwd_target = {
				sidebar = "current",
				current = "none",
			},
		},

		buffers = { follow_current_file = true },

		git_status = { window = { position = "float" } },

		-- Настройки поведения панели
		actions = {
			open_file = {
				quit_on_open = false,
				resize_window = true,
				window_picker = {
					enable = true,
					chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890",
					exclude = {
						buftype = { "help", "nofile", "prompt", "quickfix", "terminal" },
						filetype = {
							"dap-repl", "diff", "fugitive", "fugitiveblame",
							"git", "notify", "Outline", "qf", "TelescopePrompt",
							"toggleterm", "undotree"
						},
					},
				},
			},
			change_dir = { enable = true, global = false },
			remove_file = { close_window = true },
		},
	})
end
