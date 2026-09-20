-- Своя замена m4xshen/autoclose.nvim: ноль плагинов, только встроенный API.
-- Паритет со старым конфигом (см. git history lua/modules/configs/editor/autoclose.lua):
--   ( [ { -> всегда пара + курсор внутрь (escape=false, close=true)
--   ) ] } > -> прыжок вправо если справа тот же символ, иначе одиночный (escape=true)
--   < -> только rust, " ' ` -> пара, но ' выключен в rust
--   markdown и прочие ft из disabled_filetypes -> вообще без маппингов (проверка в рантайме)
-- Плюсом умные кавычки (не спамим пару внутри слов: don't -> don''t) и <BS> ест пару целиком.
-- <CR> специально НЕ трогаем: его already маппит nvim-cmp (fallback=newline), конфликт не нужен.
local M = {}

local disabled_ft = {
	alpha = true,
	checkhealth = true,
	["dap-repl"] = true,
	diff = true,
	help = true,
	log = true,
	markdown = true,
	notify = true,
	NvimTree = true,
	Outline = true,
	qf = true,
	TelescopePrompt = true,
	toggleterm = true,
	undotree = true,
	vimwiki = true,
}

local closers = { [")"] = true, ["]"] = true, ["}"] = true }

local function is_disabled()
	return disabled_ft[vim.bo.filetype] == true
end

-- col: 0-based byte-индекс курсора в insert-моде (точка вставки).
local function around()
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2]
	local prev = col > 0 and line:sub(col, col) or ""
	local next = line:sub(col + 1, col + 1) or ""
	return prev, next
end

-- Открывающая скобка: всегда пара. disable_when_touch=false как в старом конфиге.
local function make_opener(open, close)
	return function()
		if is_disabled() then
			return open
		end
		return open .. close .. "<Left>"
	end
end

-- Закрывающая: escape — прыжок через свой же символ.
local function make_closer(char)
	return function()
		if is_disabled() then
			return char
		end
		local _, next = around()
		if next == char then
			return "<Right>"
		end
		return char
	end
end

-- Кавычка: escape (прыжок) + умный close.
-- Пару ставим только на границе слова: слева начало/пробел/открывашка,
-- справа конец/пробел/закрывашка/пунктуация. Иначе печатаем одиночную,
-- чтобы don't не превращалось в don''t, а foo"bar" не плодило пары.
local function make_quote(char)
	return function()
		if is_disabled() then
			return char
		end
		if char == "'" and vim.bo.filetype == "rust" then
			return char -- lifetimes: 'a, &'a str — пару нельзя
		end
		local prev, next = around()
		if next == char then
			return "<Right>"
		end
		local prev_ok = prev == "" or prev:match("[%s%(%[{<\"'`]")
		local next_ok = next == "" or next:match("[%s%)%]}>.,;:!?\"'`]")
		if prev_ok and next_ok then
			return char .. char .. "<Left>"
		end
		return char
	end
end

-- "<": только rust. Умнее старого плагина (тот ставил <> всегда):
-- пару даём когда слева слово/] / > (дженерик Vec<, Result<, fn f<T>),
-- а справа пусто/пробел/запятая/закрывашка. "a < b" (слева пробел) — одиночный.
local function angle_open()
	if is_disabled() then
		return "<"
	end
	if vim.bo.filetype ~= "rust" then
		return "<"
	end
	local prev, next = around()
	if prev:match("[%w%>%]]") and (next == "" or next:match("[%s,%)%]}>]")) then
		return "<>" .. "<Left>"
	end
	return "<"
end

function M.setup()
	local opts = { expr = true, noremap = true, replace_keycodes = true, silent = true }

	vim.keymap.set("i", "(", make_opener("(", ")"), opts)
	vim.keymap.set("i", "[", make_opener("[", "]"), opts)
	vim.keymap.set("i", "{", make_opener("{", "}"), opts)

	vim.keymap.set("i", ")", make_closer(")"), opts)
	vim.keymap.set("i", "]", make_closer("]"), opts)
	vim.keymap.set("i", "}", make_closer("}"), opts)
	vim.keymap.set("i", ">", make_closer(">"), opts)
	vim.keymap.set("i", "<", angle_open, opts)

	vim.keymap.set("i", '"', make_quote('"'), opts)
	vim.keymap.set("i", "'", make_quote("'"), opts)
	vim.keymap.set("i", "`", make_quote("`"), opts)

-- <BS> и <C-h> съедают пару целиком: (|) -> |, иначе обычное стирание.
-- <C-h> маппим ОТДЕЛЬНО (в nvim это другой кейкод, чем <BS>):
-- так делал и старый autoclose (keys <BS>/<C-H> одним хендлером),
-- иначе оживает keymap/editor.lua `i|<C-h> -> <Left>` и C-h перестаёт стирать.
local function make_bs(fallback)
	return function()
		if is_disabled() then
			return fallback
		end
		local prev, next = around()
		local pair = prev .. next
		if
			pair == "()"
			or pair == "[]"
			or pair == "{}"
			or pair == "<>"
			or pair == '""'
			or pair == "''"
			or pair == "``"
		then
			-- <C-g>u — undo-брейкпоинт как в keymap/editor.lua для , . ;
			return "<C-g>u<BS><Del>"
		end
		return fallback
	end
end
do
	local bs = make_bs("<BS>")
	local ch = make_bs("<C-h>")
	vim.keymap.set("i", "<BS>", bs, opts)
	vim.keymap.set("i", "<C-h>", ch, opts)
end

	-- Переключение на лету без рестарта (для :ConfigHealth / отладки).
	vim.api.nvim_create_user_command("PairsStatus", function()
		local maps = {}
		for _, lhs in ipairs({ "(", "[", "{", ")", "]", "}", "<", ">", '"', "'", "`", "<BS>", "<C-h>" }) do
			local found = vim.fn.maparg(lhs, "i", false, true)
			maps[#maps + 1] = lhs .. "=" .. (found and "ok" or "missing")
		end
		local state = is_disabled() and "disabled for ft=" .. vim.bo.filetype or "active"
		vim.notify("[pairs] " .. state .. " | " .. table.concat(maps, " "), vim.log.levels.INFO)
	end, { desc = "pairs: показать статус встроенных автопар" })
end

return M
