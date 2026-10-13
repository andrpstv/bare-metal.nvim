-- scripts/regress-candy.lua — candy design system colors for khold theme.
-- Run: NVIM_DISTRO_SYNC=1 nvim --headless -c "luafile scripts/regress-candy.lua" -c 'qa!'
local failures = 0
local function check(desc, cond)
	if cond then
		print("OK " .. desc)
	else
		failures = failures + 1
		print("FAIL " .. desc)
	end
end

-- Theme may apply deferred; force it synchronously for determinism.
pcall(function()
	require("themes.black-metal-khold").apply_custom()
end)

-- Helper to read a highlight group and convert hex values.
local function get_hl(name)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	if ok then
		return hl
	end
	return {}
end

local pmenu = get_hl("Pmenu")
local pmenu_sel = get_hl("PmenuSel")
local normal = get_hl("Normal")
local normal_float = get_hl("NormalFloat")
local float_border = get_hl("FloatBorder")
local float_title = get_hl("FloatTitle")
local telescope_normal = get_hl("TelescopeNormal")
local telescope_sel = get_hl("TelescopeSelection")
local comment = get_hl("Comment")
local lsp_func_def = get_hl("@lsp.typemod.function.definition")
local search = get_hl("Search")
local cursor_insert = get_hl("CursorInsert")

-- Pmenu elevation: selection bg different from base and normal.
check("PmenuSel.bg ~= Pmenu.bg", pmenu_sel.bg and pmenu.bg and pmenu_sel.bg ~= pmenu.bg)
check("PmenuSel.bg ~= Normal.bg", pmenu_sel.bg and normal.bg and pmenu_sel.bg ~= normal.bg)

-- Telescope elevation: selection bg different from base.
check("TelescopeSelection.bg ~= TelescopeNormal.bg", telescope_sel.bg and telescope_normal.bg and telescope_sel.bg ~= telescope_normal.bg)

-- Float contrast: title fg should differ from border.
check("FloatTitle.fg ~= FloatBorder.fg", float_title.fg and float_border.fg and float_title.fg ~= float_border.fg)

-- Float elevation: nonfloat bg different from floats.
check("NormalFloat.bg ~= Normal.bg", normal_float.bg and normal.bg and normal_float.bg ~= normal.bg)

-- Comment color exact (0x6b6b6b = 6970411 in decimal).
check("Comment.fg == 0x6b6b6b", comment.fg == 0x6b6b6b)

-- Syntax hierarchy: function definition bold.
check("@lsp.typemod.function.definition is bold", lsp_func_def.bold == true)

-- Search contrast: bg is not white (#ffffff = 16777215).
check("Search.bg ~= 0xffffff", search.bg and search.bg ~= 0xffffff)

-- Cursor insert exists and has background.
check("CursorInsert exists with bg", cursor_insert.bg ~= nil)

print("failures=" .. failures)
if failures > 0 then
	vim.cmd("cquit 1")
end
