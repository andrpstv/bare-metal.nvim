-- distro/setup — «поставь всё» одной командой.
--
-- Проблема, которую это закрывает: до релиза потребителю Go требовал четырёх
-- ручных шагов (:DistroTools, :DistroBinaries, :DistroParsers, go install в
-- терминале), а про парсеры он не знал вовсе — редактор без подсветки синтаксиса.
--
-- Политика прежняя: сеть не трогается, пока пользователь не увидел план и не
-- подтвердил его ОДИН раз. Плана показывается построчно, что именно скачается и
-- откуда. Дальше шаги идут с preconfirmed — второй вопрос про тот же самый
-- архив только раздражал бы; жёсткий гард require_consent при этом остаётся в
-- каждой точке установки.
--
-- Что НЕ делает: не ставит системные пакеты (bashls/marksman помечены method
-- "system" и пропускаются — их нельзя поставить из конфига), не трогает то,
-- что уже есть, и не превращается в apt.

local M = {}

local function has_cc()
	-- cl последним: MSVC без vcvarsall всё равно не найдётся, а mingw-приоритет
	-- совпадает с treesitter.lua cc() и health (см. ниже про cl).
	for _, c in ipairs({ "cc", "gcc", "clang", "cl" }) do
		if vim.fn.executable(c) == 1 then
			return c
		end
	end
	return nil
end

--- Собрать план: что отсутствует и каким способом это ставится.
---@return table[] items { {kind=..., label=..., how=..., run=function} }
function M.plan()
	local items = {}

	local missing = require("distro.treesitter").missing_langs()
	if #missing > 0 then
		local cc = has_cc()
		if cc then
			items[#items + 1] = {
				kind = "parsers",
				label = string.format("treesitter parsers (%d)", #missing),
				how = "download + compile with " .. cc .. "; " .. #missing .. " language(s): " .. table.concat(missing, ", "),
				run = function()
					return require("distro.treesitter").install_all({ user_confirmed = true, preconfirmed = true })
				end,
			}
		else
			items[#items + 1] = {
				kind = "parsers",
				label = string.format("treesitter parsers (%d) — SKIPPED", #missing),
				how = "no C compiler (cc/gcc/clang/cl) in PATH; install a toolchain first (Windows: w64devkit via :DistroTools, or run nvim from a VS Developer prompt for cl)",
				run = nil,
			}
		end
	end

	local manifest = require("distro.manifest")
	local tools = require("distro.tools")
	for _, b in ipairs(manifest.binaries or {}) do
		if b.method ~= "system" and tools.bin_version(b) == nil then
			local how
			local can = true
			if b.method == "go" then
				if vim.fn.executable("go") ~= 1 then
					can = false
					how = "needs the 'go' toolchain, which is not in PATH"
				else
					how = "go install " .. (b.pkg or b.name)
				end
			else
				how = "curl release archive from github.com/" .. (b.repo or "?") .. " → tools/" .. b.name
			end
			items[#items + 1] = {
				kind = "binary",
				name = b.name,
				label = string.format("%s — %s", b.name, b.desc or ""),
				how = (not can) and ("SKIPPED: " .. how) or how,
				-- F3: run чинится по method, а не одним ad-hoc: go-бинарники
				-- ставит install_go, релизы — ad-hoc spec. Иначе план врал
				-- ("runnable"), а выполнение падало с No curl source.
				run = can and function()
					if b.method == "go" then
						return require("distro.tools").install_go(b.name, { user_confirmed = true, preconfirmed = true })
					end
					return require("distro.tools").install_tool_ad_hoc(b)
				end or nil,
			}
		end
	end
	return items
end

function M.run(opts)
	opts = opts or {}
	local items = M.plan()
	local runnable = vim.tbl_filter(function(i)
		return i.run ~= nil
	end, items)

	if #items == 0 then
		vim.notify(
			"[setup] Nothing to install: every treesitter parser and binary in the manifest is present.\n"
				.. "You can still see the full list with :DistroBinaries.",
			vim.log.levels.INFO,
			{ title = "distro setup" }
		)
		return
	end

	if #runnable == 0 then
		local why = {}
		for _, i in ipairs(items) do
			why[#why + 1] = "  " .. i.label .. "\n      " .. i.how
		end
		vim.notify(
			"[setup] Nothing can be installed automatically right now:\n" .. table.concat(why, "\n"),
			vim.log.levels.WARN,
			{ title = "distro setup" }
		)
		return
	end

	local lines = {
		"Install the following? Each line says exactly what will be downloaded:",
		"",
	}
	for _, i in ipairs(items) do
		lines[#lines + 1] = "  " .. i.label
		lines[#lines + 1] = "      " .. i.how
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Go installs land in your GOPATH/bin, outside this config."
	lines[#lines + 1] = "Release archives land in tools/ inside this config."

	-- require_consent, а не просто confirm: без UI подтверждать нечем.
	-- F3: yes пробрасываем от вызывающего (:DistroSetup --yes), хардкода нет:
	-- headless без флага отказывается вместо молчаливого сетевого выхода.
	local ok_consent, err_consent = pcall(require("distro.install").require_consent, { user_confirmed = true, yes = opts.yes })
	if not ok_consent then
		vim.notify("[setup] " .. tostring(err_consent), vim.log.levels.WARN, { title = "distro setup" })
		return
	end
	if #vim.api.nvim_list_uis() == 0 and not opts.yes then
		vim.notify("[setup] Canceled: headless needs --yes (nothing was downloaded).", vim.log.levels.WARN, { title = "distro setup" })
		return
	end
	if vim.fn.confirm(table.concat(lines, "\n"), "&Install\n&No", 2) ~= 1 then
		vim.notify("[setup] Canceled. Nothing was downloaded.", vim.log.levels.INFO, { title = "distro setup" })
		return
	end

	local done, failed, skipped = 0, {}, 0
	for _, i in ipairs(items) do
		if not i.run then
			skipped = skipped + 1
		else
			local ok, msg = i.run()
			if ok then
				done = done + 1
			else
				failed[#failed + 1] = i.label .. ": " .. tostring(msg)
			end
		end
	end

	local report = { string.format("[setup] installed %d of %d", done, #runnable) }
	if skipped > 0 then
		report[#report + 1] = "skipped " .. skipped .. " (see the plan above for the reason)"
	end
	if #failed > 0 then
		report[#report + 1] = "failed:"
		for _, f in ipairs(failed) do
			report[#report + 1] = "  " .. f
		end
	end
	vim.notify(
		table.concat(report, "\n"),
		#failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO,
		{ title = "distro setup" }
	)
end

return M
