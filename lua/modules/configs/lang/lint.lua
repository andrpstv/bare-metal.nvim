return function()
	local lint = require("lint")

	lint.linters_by_ft = {
		go = { "golangcilint" },
	}

	local mason_registry = require("mason-registry")

	local function ensure_golangci_lint()
		if not mason_registry.is_installed("golangci-lint") then
			vim.notify("Installing golangci-lint via Mason...", vim.log.levels.INFO, { title = "lint" })
			local pkg = mason_registry.get_package("golangci-lint")
			pkg:install():once("closed", vim.schedule_wrap(function()
				if pkg:is_installed() then
					vim.notify("golangci-lint installed", vim.log.levels.INFO, { title = "lint" })
				end
			end))
		end
	end

	ensure_golangci_lint()

	lint.linters.golangcilint.ignore_exitcode = true

	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, {
		callback = function()
			lint.try_lint()
		end,
	})
end
