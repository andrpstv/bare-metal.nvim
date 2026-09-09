-- https://github.com/mfussenegger/nvim-dap/wiki/Debug-Adapter-installation#go
return function()
	local dap = require("dap")
	local utils = require("modules.utils.dap")

	dap.adapters.go = {
		type = "server",
		port = "${port}",
		executable = {
			command = "dlv",
			args = { "dap", "--listen", "127.0.0.1:${port}", "--headless", "--check-go-version=false" },
		},
	}
	dap.configurations.go = {
		{
			type = "go",
			name = "Debug (file)",
			request = "launch",
			cwd = "${workspaceFolder}",
			program = utils.input_file_path(),
			console = "integratedTerminal",
			showLog = true,
			stopOnEntry = false,
		},
		{
			type = "go",
			name = "Debug (file with args)",
			request = "launch",
			cwd = "${workspaceFolder}",
			program = utils.input_file_path(),
			args = utils.input_args(),
			console = "integratedTerminal",
			showLog = true,
			stopOnEntry = false,
		},
		{
			type = "go",
			name = "Debug (executable)",
			request = "launch",
			cwd = "${workspaceFolder}",
			program = utils.input_exec_path(),
			args = utils.input_args(),
			console = "integratedTerminal",
			mode = "exec",
			showLog = true,
			stopOnEntry = false,
		},
		{
			type = "go",
			name = "Debug (test file)",
			request = "launch",
			cwd = "${workspaceFolder}",
			program = utils.input_file_path(),
			console = "integratedTerminal",
			mode = "test",
			showLog = true,
			stopOnEntry = false,
		},
		{
			type = "go",
			name = "Debug (using go.mod)",
			request = "launch",
			cwd = "${workspaceFolder}",
			program = "./${relativeFileDirname}",
			console = "integratedTerminal",
			mode = "test",
			showLog = true,
			stopOnEntry = false,
		},
	}
end
