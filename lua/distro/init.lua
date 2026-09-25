-- distroManager commands — the ONLY network entry points.
-- Every mutating command requires explicit confirmation (install.require_consent).

local M = {}

function M.setup()
	vim.api.nvim_create_user_command("Distro", function()
		require("distro.ui").open()
	end, { desc = "distro: open plugin manager (no downloads on open)" })

	vim.api.nvim_create_user_command("DistroInstall", function(opts)
		local args = vim.trim(opts.args or "")
		local yes = args:match("%-%-yes") ~= nil
		local name = args:gsub("%s*%-%-yes%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
		name = name == "" and nil or name
		if name then
			local entry = require("distro.manifest").get(name)
			if not entry then
				vim.notify("Unknown plugin '" .. name .. "'. Open :Distro to see the list. No changes made.", vim.log.levels.ERROR)
				return
			end
			local install = require("distro.install")
			local mirror = require("distro.mirror")
			local src, src_err = install.resolve_source(entry)
			if not src then
				vim.notify(src_err, vim.log.levels.ERROR)
				return
			end
			local preview_lines = {
				"Install '" .. entry.name .. "' (" .. entry.ref:sub(1, 7) .. ")?",
				"To: pack/distro/" .. entry.kind .. "/" .. entry.name,
				"Version will be recorded in distro-lock.json. [y/N]",
			}
			for _, l in ipairs(install.source_lines(src)) do
				preview_lines[#preview_lines + 1] = l
			end
			local preview = table.concat(preview_lines, "\n")
			if not yes and vim.fn.confirm(preview, "&Yes\n&No", 2) ~= 1 then
				vim.notify("Installation canceled. No changes were made.", vim.log.levels.INFO)
				return
			end
			local ok, msg = install.install_one(entry, { user_confirmed = true, yes = yes or nil })
			if ok then
				-- activate right away so :DistroInstall feels like lazy's install
				require("distro.loader").load(name)
			end
			vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
		else
			require("distro.ui").open()
			vim.notify("Pick a plugin with I, or run :DistroInstall <name>. Nothing was downloaded.", vim.log.levels.INFO)
		end
	end, { nargs = "*", desc = "distro: install plugin(s) via curl (confirm-gated)", complete = function()
		local out = {}
		for _, p in ipairs(require("distro.manifest").plugins) do
			out[#out + 1] = p.name
		end
		for _, p in ipairs(require("distro.manifest").catalog or {}) do
			out[#out + 1] = p.name
		end
		return out
	end })

	vim.api.nvim_create_user_command("DistroUpdate", function()
		require("distro.ui").do_sync_outdated()
	end, { desc = "distro: sync outdated to manifest pin (confirm-gated)" })

	vim.api.nvim_create_user_command("DistroClean", function()
		require("distro.ui").do_clean()
	end, { desc = "distro: clean unused (confirm-gated)" })

	vim.api.nvim_create_user_command("DistroCheck", function()
		local status = require("distro.lock").status()
		local n_missing = 0
		for _, st in pairs(status) do
			if st ~= "installed" then
				n_missing = n_missing + 1
			end
		end
		vim.notify("Distro check: local only, no network (" .. require("distro.mirror").label() .. "). " .. n_missing .. " item(s) need attention. Open :Distro for details.", vim.log.levels.INFO)
	end, { desc = "distro: local check (no network)" })

	vim.api.nvim_create_user_command("DistroTools", function(opts)
		local a = vim.trim(opts.args or "")
		if a ~= "" and a ~= "--install" then
			vim.notify("Usage: :DistroTools [--install <tool>]. No changes made.", vim.log.levels.WARN)
			return
		end
		if a:match("^%-%-install") then
			local tool = a:gsub("^%-%-install%s*", "")
			if tool == "" then
				vim.notify("Usage: :DistroTools --install <tool>  (e.g. fzf). No changes made.", vim.log.levels.WARN)
				return
			end
			local ok, msg = require("distro.tools").install_tool(tool, { user_confirmed = true })
			vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
			return
		end
		local res = require("distro.tools").check_all()
		local lines = { "Tools (local check, no downloads):" }
		for name, r in pairs(res) do
			lines[#lines + 1] = string.format("  %s  %s  %s", r.ok and "●" or "○", name, r.ok and (r.version or "ok") or "missing")
			if not r.ok and r.hint then
				local h = r.hint[require("core.global").is_mac and "mac" or (require("core.global").is_windows and "win" or "linux")]
				if h then
					lines[#lines + 1] = "      Next: " .. h
				end
			end
		end
		lines[#lines + 1] = "Install one via :DistroTools --install <tool> (asks first)."
		vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
	end, { nargs = "*", desc = "distro: check/install tools (install is confirm-gated)" })

	vim.api.nvim_create_user_command("DistroParsers", function(opts)
		local a = vim.trim(opts.args or "")
		if a == "" then
			local langs = require("distro.treesitter").installed_langs()
			vim.notify("Installed parsers (" .. #langs .. "): " .. (#langs > 0 and table.concat(langs, ", ") or "none") .. ". Install one via :DistroParsers <lang> (asks first).", vim.log.levels.INFO)
			return
		end
		if a == "--all" then
			local ok, msg = require("distro.treesitter").install_all({ user_confirmed = true })
			vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
			return
		end
		local ok, msg = require("distro.treesitter").install_lang(a, { user_confirmed = true })
		vim.notify(msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
	end, { nargs = "?", desc = "distro: parsers (confirm-gated)" })

	vim.api.nvim_create_user_command("DistroBench", function()
		require("distro.bench").run()
	end, { desc = "distro: benchmark this machine (open times, gd/gr RTT)" })

	vim.api.nvim_create_user_command("DistroBinaries", function()
		require("distro.tools").open_binaries()
	end, { desc = "distro: binaries menu (LSP, linters, formatters)" })

	vim.api.nvim_create_user_command("DistroMirror", function(opts)
		require("distro.mirror_cmd").run(vim.trim(opts.args or ""))
	end, {
		nargs = "*",
		desc = "distro: corporate mirror (status|on|off|set-url|set-args|clear-args|set-token|test)",
		complete = function()
			return { "status", "menu", "on", "off", "set-url", "set-args", "clear-args", "set-token", "test" }
		end,
	})
end

return M
