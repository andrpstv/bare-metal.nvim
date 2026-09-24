-- ТЕСТ (не коммитить итог без ок): DAP для Go через delve, классический UI.
-- Снос: удалить этот файл + блок nvim-dap из plugins/lang.lua + `:DistroClean`.
return function()
	local dap = require("dap")
	local dapui = require("dapui")
	local icons = {
		ui = require("modules.utils.icons").get("ui"),
		dap = require("modules.utils.icons").get("dap"),
	}

	require("dap-go").setup({
		delve = {
			-- detached=false нужен на Windows для delve < 1.24;
			-- дефолт плагина уже учитывает win32, дублируем явно для читаемости.
			detached = vim.fn.has("win32") == 0,
			initialize_timeout_sec = 20,
		},
	})

	-- Классика как была: справа scopes/watches/stacks/breakpoints,
	-- снизу console/repl, кнопки-стрелки как в VS Code.
	dapui.setup({
		force_buffers = true,
		icons = {
			expanded = icons.ui.ArrowOpen,
			collapsed = icons.ui.ArrowClosed,
			current_frame = icons.ui.Indicator,
		},
		mappings = {
			edit = "e",
			expand = { "<CR>", "<2-LeftMouse>" },
			open = "o",
			remove = "d",
			repl = "r",
			toggle = "t",
		},
		layouts = {
			{
				elements = {
					{ id = "scopes", size = 0.3 },
					{ id = "watches", size = 0.3 },
					{ id = "stacks", size = 0.3 },
					{ id = "breakpoints", size = 0.1 },
				},
				size = 0.3,
				position = "right",
			},
			{
				elements = {
					{ id = "console", size = 0.55 },
					{ id = "repl", size = 0.45 },
				},
				position = "bottom",
				size = 0.25,
			},
		},
		controls = {
			enabled = true,
			element = "repl",
			icons = {
				pause = icons.dap.Pause,
				play = icons.dap.Play,
				step_into = icons.dap.StepInto,
				step_over = icons.dap.StepOver,
				step_out = icons.dap.StepOut,
				step_back = icons.dap.StepBack,
				run_last = icons.dap.RunLast,
				terminate = icons.dap.Terminate,
			},
		},
		floating = {
			border = "single",
			mappings = { close = { "q", "<Esc>" } },
		},
		render = { indent = 1, max_value_lines = 85 },
	})

	dap.listeners.after.event_initialized["dapui_config"] = function()
		dapui.open({ reset = true })
	end
	dap.listeners.before.event_terminated["dapui_config"] = function()
		dapui.close()
	end
	dap.listeners.before.event_exited["dapui_config"] = function()
		dapui.close()
	end
	dap.listeners.before.disconnect["dapui_config"] = function()
		dapui.close()
	end

	-- Значки в gutter (hl-группы Dap* уже заданы темой black-metal-khold).
	vim.fn.sign_define("DapBreakpoint", { text = icons.dap.Breakpoint, texthl = "DapBreakpoint", linehl = "", numhl = "" })
	vim.fn.sign_define(
		"DapBreakpointCondition",
		{ text = icons.dap.BreakpointCondition, texthl = "DapBreakpoint", linehl = "", numhl = "" }
	)
	vim.fn.sign_define("DapStopped", { text = icons.dap.Stopped, texthl = "DapStopped", linehl = "", numhl = "" })
	vim.fn.sign_define(
		"DapBreakpointRejected",
		{ text = icons.dap.BreakpointRejected, texthl = "DapBreakpoint", linehl = "", numhl = "" }
	)
	vim.fn.sign_define("DapLogPoint", { text = icons.dap.LogPoint, texthl = "DapLogPoint", linehl = "", numhl = "" })

	-- <leader>d* свободен (проверено по keymap/: заняты только pd/gd/gD).
	local map = function(lhs, rhs, desc)
		vim.keymap.set("n", lhs, rhs, { noremap = true, silent = true, desc = "dap: " .. desc })
	end
	map("<leader>db", function()
		dap.toggle_breakpoint()
	end, "Toggle breakpoint")
	map("<leader>dB", function()
		dap.set_breakpoint(vim.fn.input("Breakpoint condition: "))
	end, "Conditional breakpoint")
	map("<leader>dc", function()
		dap.continue()
	end, "Continue")
	map("<leader>di", function()
		dap.step_into()
	end, "Step into")
	map("<leader>do", function()
		dap.step_over()
	end, "Step over")
	map("<leader>dO", function()
		dap.step_out()
	end, "Step out")
	map("<leader>dr", function()
		dap.repl.toggle()
	end, "Toggle repl")
	map("<leader>dq", function()
		dap.terminate()
	end, "Terminate")
	map("<leader>du", function()
		dapui.toggle()
	end, "Toggle UI")
	map("<leader>dt", function()
		require("dap-go").debug_test()
	end, "Debug test under cursor")
	map("<leader>dl", function()
		require("dap-go").debug_last_test()
	end, "Debug last test")
	-- Hover переменной под курсором во всплывашке (как было через floating).
	map("<leader>dh", function()
		require("dap.ui.widgets").hover()
	end, "Hover variable")
end
