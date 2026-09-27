local M = {}

M.plugin = "metalelf0/black-metal-theme-neovim"

-- Defer the whole apply (base + custom scheduling) by N ms. Only used when
-- perf_lean + axis theme is ON and there is a UI. ~6 ms of black-metal sourcing
-- moves off the startup path; the cost is a possible brief flash of the default
-- colourscheme on the first frame. Headless / NVIM_DISTRO_SYNC stay synchronous.
M.THEME_DEFER_MS = 50

local function defer_allowed()
	local ok, perf = pcall(require, "core.perf")
	if not ok or not perf.lean_axis("theme") then
		return false
	end
	-- Nothing to wait for without a UI, and scripts need determinism.
	if #vim.api.nvim_list_uis() == 0 or vim.env.NVIM_DISTRO_SYNC == "1" then
		return false
	end
	return true
end

-- ЕДИНСТВЕННАЯ точка, где гарантируется гард termguicolors для темы.
--
-- termguicolors=true ставится ВНУТРИ black-metal load() (то есть ДО любого
-- возможного падения), поэтому откат в habamax без гарда оставил бы 24-битный
-- режим на dumb/screen/NO_COLOR. Чтобы нельзя было добавить новый путь отката и
-- забыть про гард, весь код применения темы ходит через эту обёртку: enforce()
-- вызывается ПОСЛЕ pcall в любом случае — и при успехе, и при откате.
local function with_term_guard(fn)
	local ok, res = pcall(fn)
	pcall(function()
		require("core.term_guard").enforce()
	end)
	return ok, res
end

M.setup = function()
	-- Paint-critical: base colourscheme first (fast, no custom table) so the
	-- first frame is dark and correct, with no white flash. The whole custom
	-- pass below is scheduled separately (1-2 frames of base colours, invisible;
	-- headless — synchronous for script determinism).
	local function apply_base()
		-- Откат в habamax лежит ВНУТРИ обёртки, поэтому гард отработает и на нём.
		local ok, res = with_term_guard(function()
			if pcall(vim.cmd, "colorscheme khold") then
				vim.g.colors_name = vim.g.colors_name or "khold"
				return true
			end
			vim.notify("[theme] colorscheme khold failed — fallback habamax", vim.log.levels.ERROR)
			pcall(vim.cmd, "colorscheme habamax")
			return false
		end)
		return ok and res or false
	end
	local function apply_custom()
		-- MINIMAL trace: один спан на deferred-apply кастома (дорогая часть
		-- ~90 highlights). Внутренние require не трейсим — только apply.
		local ok_t, tr = pcall(require, "distro.trace")
		if ok_t and tr.enabled then
			tr.span("theme/custom", M.apply_custom)
		else
			M.apply_custom()
		end
		M._custom_applied = true
	end

	-- Turbo/idle scheduling of the custom pass. Identical to the previous
	-- inline body — extracted only so both the sync and deferred entry points
	-- can share it without duplicating it.
	local function schedule_custom()
		-- PERF_DEFER (D): custom highlights ride idle (once CursorHold/InsertLeave
		-- + 300ms timer — pattern from distro/loader.lua:297-328); the base
		-- colourscheme above is already synchronous (no white flash).
		-- Headless/SYNC — synchronous.
		local ok_perf, perf_mod = pcall(require, "core.perf")
		local defer_on = ok_perf and perf_mod.defer_on and perf_mod.defer_on() or false
		if #vim.api.nvim_list_uis() == 0 or vim.env.NVIM_DISTRO_SYNC == "1" then
			apply_custom()
		elseif defer_on then
			local done = false
			-- Live 300ms timer: after :Colorscheme it must die, otherwise a
			-- dangling callback would repaint someone else's theme with ours.
			local timer
			---Synchronous drain for :PerfDeferOff/:TurboOff (core.perf). Idempotent.
			function M.apply_pending()
				if done then
					return
				end
				-- Custom belongs to khold: after :Colorscheme gruvbox we must
				-- not paint it (otherwise the whole foreign palette shifts).
				if vim.g.colors_name ~= "khold" then
					return
				end
				done = true
				apply_custom()
			end
			local function once()
				M.apply_pending()
			end
			local grp = vim.api.nvim_create_augroup("TurboKholdCustom", { clear = true })
			vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI", "InsertLeave" }, {
				group = grp,
				once = true,
				desc = "turbo: idle apply khold custom highlights",
				callback = function()
					vim.schedule(once)
				end,
			})
			vim.api.nvim_create_autocmd("ColorScheme", {
				group = grp,
				desc = "turbo: drop pending khold custom on colorscheme switch",
				callback = function()
					if timer then
						timer:stop()
						timer:close()
						timer = nil
					end
					done = true
				end,
			})
			timer = vim.defer_fn(function()
				timer = nil
				vim.schedule(once)
			end, 300)
		else
			vim.schedule(function()
				-- Same guard: if the colours were switched between setup() and
				-- the frame, there is no previous theme to customise.
				if vim.g.colors_name ~= "khold" then
					return
				end
				apply_custom()
			end)
		end
	end

	local function apply_all()
		if apply_base() then
			schedule_custom()
		end
	end

	-- Flag off (default) → exactly the previous synchronous path, byte for byte.
	if defer_allowed() then
		local pending = true
		local function drain()
			if not pending then
				return
			end
			pending = false
			apply_all()
		end
		-- :PerfDeferOff/:TurboOff must still be able to flush a pending deferred apply.
		M.apply_pending = drain
		vim.defer_fn(drain, M.THEME_DEFER_MS)
		return
	end

	apply_all()
end

--- Полная кастомизация поверх базы (дорогая часть: ~90 highlights + load).
--- Тело вынесено в apply_custom_body: публичная обёртка ниже прогоняет его
--- через with_term_guard, поэтому гард termguicolors гарантирован и на путях
--- отката в habamax, а не только по «успеху».
local apply_custom_body = function()
	-- Бленды в эстетике темы (считаем её же Util; фолбэк — руками).
	local blend_ok, Util = pcall(require, "black-metal.util")
	local function blend(fg, coeff, bg, fallback)
		if blend_ok and Util.blend then
			local ok, res = pcall(Util.blend, fg, coeff, bg)
			if ok and res then
				return res
			end
		end
		return fallback
	end
	local ok, err = pcall(require("black-metal").setup, {
		theme = "khold",
		comments = { italic = true },
		-- term_colors ВЫКЛЮЧЕНЫ осознанно: в палитре khold перепутаны
		-- имена (diag_red — teal, diag_green — red), иначе в :terminal
		-- красный/зелёный поменяны местами (git diff врёт).
		term_colors = false,
		highlights = {
			["@module"] = { fg = "$fg" },
			["@lsp.type.module"] = { fg = "$fg" },
			["@lsp.type.namespace"] = { fg = "$fg" },
			["@keyword"] = { fg = "#974b46" },
			["@keyword.type"] = { fg = "#974b46" },
			["@keyword.return"] = { fg = "#974b46" },
			["@keyword.conditional"] = { fg = "#974b46" },
			["@keyword.operator"] = { fg = "#974b46" },
			["@keyword.exception"] = { fg = "#974b46" },
			Keyword = { fg = "#974b46" },
			Statement = { fg = "#974b46" },
			Conditional = { fg = "#974b46" },
			Exception = { fg = "#974b46" },
			Include = { fg = "$fg" },
			["@keyword.import"] = { fg = "$fg" },
			["@type"] = { fg = "#888888" },
			["@type.builtin"] = { fg = "#888888" },
			["@type.definition"] = { fg = "#888888" },
			["@lsp.type.type"] = { fg = "#888888" },
			["@lsp.type.class"] = { fg = "#888888" },
			["@lsp.type.struct"] = { fg = "#888888" },
			["@lsp.type.interface"] = { fg = "#888888" },
			["@lsp.type.enum"] = { fg = "#888888" },
			Type = { fg = "#888888" },
			DiagnosticError = { fg = "#af3a3a" },
			DiagnosticWarn = { fg = "#aaaaaa" },
			DiagnosticInfo = { fg = "#999999", fmt = "italic" },
			DiagnosticHint = { fg = "#888888", fmt = "italic" },
			DiagnosticUnderlineError = { sp = "#af3a3a", fmt = "underline" },
			DiagnosticUnderlineWarn = { sp = "#aaaaaa", fmt = "underline" },
			DiagnosticVirtualTextError = { fg = "#af3a3a" },
			DiagnosticVirtualTextWarn = { fg = "#aaaaaa" },
			DiagnosticVirtualTextInfo = { fg = "#999999" },
			DiagnosticVirtualTextHint = { fg = "#888888" },
			-- Diff: в палитре перепутаны diag_red/diag_green, поэтому
			-- added светился красным, а deleted — зелёным. Правим явно
			-- в тех же пропорциях бленда, что у темы.
			DiffAdd = { bg = blend("#5f8787", 0.3, "#000000", "#1d2929") },
			DiffDelete = { bg = blend("#974b46", 0.4, "#000000", "#3c1e1c") },
			ErrorMsg = { fg = "#af3a3a", fmt = "bold" },
			SpellBad = { sp = "#af3a3a", fmt = "undercurl" },
			SpellCap = { sp = "#af3a3a", fmt = "undercurl" },
			SpellLocal = { sp = "#888888", fmt = "undercurl" },
			SpellRare = { sp = "#888888", fmt = "undercurl" },
			debugPC = { fg = "#af3a3a" },
			debugBreakpoint = { fg = "#af3a3a" },
			-- Git signs: полный набор (иначе Ln/Nr/Cul-варианты берут
			-- инвертированные diag_* из темы).
			GitSignsAdd = { fg = "#5f8787" },
			GitSignsAddLn = { fg = "#5f8787" },
			GitSignsAddNr = { fg = "#5f8787" },
			GitSignsAddCul = { fg = "#5f8787" },
			GitSignsChange = { fg = "#888888" },
			GitSignsChangeLn = { fg = "#888888" },
			GitSignsChangeNr = { fg = "#888888" },
			GitSignsChangeCul = { fg = "#888888" },
			GitSignsDelete = { fg = "#974b46" },
			GitSignsDeleteLn = { fg = "#974b46" },
			GitSignsDeleteNr = { fg = "#974b46" },
			GitSignsDeleteCul = { fg = "#974b46" },
			-- Diffview: статусы файлов (M/D/?) в правильных цветах.
			DiffviewStatusDeleted = { fg = "#974b46" },
			DiffviewStatusUnknown = { fg = "#974b46" },
			DiffviewStatusBroken = { fg = "#974b46" },
			DiffviewStatusAdded = { fg = "#c1c1c1" },
			DapBreakpoint = { fg = "#af3a3a" },
			DapBreakpointCondition = { fg = "#af3a3a" },
			DapBreakpointRejected = { fg = "#888888" },
			DapStopped = { fg = "#5f8787" },
			DapLogPoint = { fg = "#aaaaaa" },
			Search = { fg = "#000000", bg = "#ffffff" },
			IncSearch = { fg = "#000000", bg = "#ffffff", fmt = "bold" },
			CurSearch = { fg = "#ffffff", bg = "#af3a3a", fmt = "bold" },
			Substitute = { fg = "#ffffff", bg = "#af3a3a" },
		},
	})
	if not ok then
		vim.notify("[theme] black-metal setup failed: " .. tostring(err) .. " — fallback habamax", vim.log.levels.ERROR)
		pcall(vim.cmd, "colorscheme habamax")
		return
	end
	local load_ok, load_err = pcall(require("black-metal").load)
	if not load_ok then
		vim.notify("[theme] black-metal load failed: " .. tostring(load_err) .. " — fallback habamax", vim.log.levels.ERROR)
		pcall(vim.cmd, "colorscheme habamax")
		return
	end
	-- Второй вызов load() (первый — на базовой теме) опять ставит
	-- termguicolors=true. Гарантированный гард даёт with_term_guard ниже,
	-- в том числе если этот load() упал и ушёл в habamax.
	-- Идемпотентно, на обычном терминале — no-op.
	-- Идемпотентный реаплай кастома: :colorscheme khold сносит highlights,
	-- т.к. colors/khold.lua делает setup({})+load без них.
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("KholdCustomHl", { clear = true }),
		callback = function(ev)
			if ev.match == "khold" then
				for _, g in ipairs({
					"GitSignsAdd", "GitSignsAddLn", "GitSignsAddNr", "GitSignsAddCul",
					"GitSignsChange", "GitSignsChangeLn", "GitSignsChangeNr", "GitSignsChangeCul",
					"GitSignsDelete", "GitSignsDeleteLn", "GitSignsDeleteNr", "GitSignsDeleteCul",
				}) do
					local fg = g:match("Add") and "#5f8787" or (g:match("Delete") and "#974b46" or "#888888")
					pcall(vim.api.nvim_set_hl, 0, g, { fg = fg })
				end
			end
		end,
	})
end

--- Public entry point. Always returns through with_term_guard, so the
--- termguicolors guard runs on EVERY path — success, habamax fallback, or an
--- unexpected throw inside the body. Adding a new fallback inside
--- apply_custom_body can no longer silently skip the guard.
M.apply_custom = function()
	with_term_guard(apply_custom_body)
end

return M
