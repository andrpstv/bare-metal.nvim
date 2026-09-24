-- distroManager mirror_cmd — :DistroMirror implementation.
-- Token is session-memory only. File writes never include a token.

local M = {}

local function show_status()
	local mirror = require("distro.mirror")
	local eff = mirror.effective()
	local lines = {
		"Mirror status:",
		"  mode:     " .. (eff.enabled and "corporate" or "github (codeload)"),
	}
	if eff.enabled then
		lines[#lines + 1] = "  template: " .. mirror.redact(eff.url_template)
		lines[#lines + 1] = "  args:     " .. (#eff.extra_args > 0 and table.concat(eff.extra_args, " ") or "(none)")
		if mirror.insecure(eff.extra_args) then
			lines[#lines + 1] = "  WARNING: TLS verification DISABLED (--insecure)."
		end
		local tok = mirror.token()
		lines[#lines + 1] = "  token:    " .. (tok and "set (" .. eff.token_env .. ")" or "MISSING (" .. eff.token_env .. " empty)")
	else
		lines[#lines + 1] = "  enable with :DistroMirror on  (needs url_template configured)"
	end
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

function M.run(argstr)
	local mirror = require("distro.mirror")
	local sub, rest = argstr:match("^(%S*)%s*(.*)$")
	sub = sub or ""
	rest = rest or ""

	if sub == "" or sub == "status" then
		show_status()
	elseif sub == "menu" then
		require("distro.ui").open_mirror()
	elseif sub == "on" then
		local eff = mirror.effective()
		if eff.url_template == "" then
			vim.notify("Cannot enable: no url_template. Set one via :DistroMirror set-url <template> (see docs/distro/06-corporate-mirror.md). No changes made.", vim.log.levels.ERROR)
			return
		end
		local file = mirror.read_file()
		file.enabled = true
		local ok, err = mirror.write_file(file)
		vim.notify(ok and "Corporate mirror enabled (persisted to " .. mirror.LOCAL_FILE .. ", gitignored)." or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
	elseif sub == "off" then
		mirror.set_session({ enabled = false })
		local file = mirror.read_file()
		file.enabled = false
		local ok, err = mirror.write_file(file)
		vim.notify(ok and "Corporate mirror disabled. Back to github." or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
	elseif sub == "set-url" then
		if rest == "" then
			vim.notify("Usage: :DistroMirror set-url <template with {owner}{repo}{ref}{branch}{token}>. No changes made.", vim.log.levels.WARN)
			return
		end
		local file = mirror.read_file()
		file.url_template = rest
		local ok, err = mirror.write_file(file)
		vim.notify(ok and "Mirror URL template saved (token is NOT stored — use env). Run :DistroMirror test." or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
	elseif sub == "set-args" then
		local args = {}
		for a in rest:gmatch("%S+") do
			args[#args + 1] = a
		end
		local file = mirror.read_file()
		file.extra_args = args
		local ok, err = mirror.write_file(file)
		local warn = ""
		if ok and mirror.insecure(args) then
			warn = " WARNING: --insecure disables TLS verification."
		end
		vim.notify(ok and ("Mirror curl args saved." .. warn) or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
	elseif sub == "clear-args" then
		local file = mirror.read_file()
		file.extra_args = {}
		local ok, err = mirror.write_file(file)
		vim.notify(ok and "Mirror curl args cleared." or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
	elseif sub == "set-token" then
		if #vim.api.nvim_list_uis() == 0 then
			vim.notify("Interactive prompt needs a UI. Set " .. (mirror.effective().token_env) .. " env var instead. No changes made.", vim.log.levels.ERROR)
			return
		end
		local tok = vim.fn.inputsecret("Mirror token (session-only, never stored): ")
		if not tok or tok == "" then
			vim.notify("Empty token. No changes made.", vim.log.levels.WARN)
			return
		end
		mirror.set_session({ token = tok })
		vim.notify("Token kept in session memory only. It will be forgotten on exit.", vim.log.levels.INFO)
	elseif sub == "test" then
		M.test()
	else
		vim.notify("Usage: :DistroMirror status|on|off|set-url|set-args|clear-args|set-token|test. No changes made.", vim.log.levels.WARN)
	end
end

--- Probe reachability with a HEAD request (no body download).
function M.test()
	local mirror = require("distro.mirror")
	local install = require("distro.install")
	local eff = mirror.effective()
	-- smallest vendored plugin as probe target
	local entry = require("distro.manifest").get("plenary.nvim") or require("distro.manifest").plugins[1]
	local src, err
	if eff.enabled then
		src, err = install.resolve_source(entry)
		if not src then
			vim.notify(err, vim.log.levels.ERROR)
			return
		end
	else
		src = { url = install.tarball_url(entry.repo, entry.ref), extra_args = eff.extra_args }
	end
	vim.notify("Probing " .. mirror.redact(src.url) .. " …", vim.log.levels.INFO)
	local ok, code = install.probe(src.url, src.extra_args)
	if ok then
		vim.notify("Mirror OK (HTTP " .. code .. ", headers only, nothing downloaded).", vim.log.levels.INFO)
	else
		vim.notify("Mirror probe FAILED (" .. code .. "). Check URL/token/network. Nothing downloaded.", vim.log.levels.ERROR)
	end
end

return M
