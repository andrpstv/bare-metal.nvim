-- keymap/ru — русские дубли хоткеев (та же физическая клавиша).
--
-- Проблема: на РУ-раскладке ОС langmap чинит только builtin-команды
-- (hjkl, w, f/t-моушены). Кастомные маппинги (<leader>ff, <C-p>, gd, ]q...)
-- при nolangremap (дефолт Neovim) НЕ транслируются и молча не срабатывают.
-- Плюс терминалы шлют <C-ы> вместо <C-s> — Ctrl/Alt тоже ломаются.
--
-- Решение: обёртка над vim.keymap.set (+ api-варианты) автоматически ставит
-- РУ-дубль каждого EN-маппинга: <leader>ff -> <leader>аа, <C-p> -> <C-з>,
-- gd -> вд, ]q -> ъй, jj -> оо. RHS тот же, desc тот же.
--
-- Что НЕ дублируем (осознанно):
--   * insert/cmdline одиночные ",.;" — это ввод текста, а не хоткеи:
--     дубль "б" вместо "," ломал бы печать русского текста;
--   * <Plug>/<SID> — служебные, транслитерация дала бы мусор.
--
-- Подключается ПЕРВОЙ строкой keymap/init.lua, до всех map(), поэтому
-- покрывает и поздние buffer-local LSP-маппинги (LspAttach).

local M = {}

-- EN (позиция) -> RU (что печатает та же клавиша в JCUKEN).
-- Строили по физряду: `qwerty... <-> йцукен..., [->х, ]->ъ, ;->ж, '->э,
-- ,->б, .->ю, /->. (точка), `->ё + шифтовые пары.
local en_to_ru = {
	q = "й",
	w = "ц",
	e = "у",
	r = "к",
	t = "е",
	y = "н",
	u = "г",
	i = "ш",
	o = "щ",
	p = "з",
	["["] = "х",
	["]"] = "ъ",
	a = "ф",
	s = "ы",
	d = "в",
	f = "а",
	g = "п",
	h = "р",
	j = "о",
	k = "л",
	l = "д",
	[";"] = "ж",
	["'"] = "э",
	z = "я",
	x = "ч",
	c = "с",
	v = "м",
	b = "и",
	n = "т",
	m = "ь",
	[","] = "б",
	["."] = "ю",
	["/"] = ".",
	["`"] = "ё",
	Q = "Й",
	W = "Ц",
	E = "У",
	R = "К",
	T = "Е",
	Y = "Н",
	U = "Г",
	I = "Ш",
	O = "Щ",
	P = "З",
	["{"] = "Х",
	["}"] = "Ъ",
	A = "Ф",
	S = "Ы",
	D = "В",
	F = "А",
	G = "П",
	H = "Р",
	J = "О",
	K = "Л",
	L = "Д",
	[":"] = "Ж",
	['"'] = "Э",
	Z = "Я",
	X = "Ч",
	C = "С",
	V = "М",
	B = "И",
	N = "Т",
	M = "Ь",
	["<"] = "Б",
	[">"] = "Ю",
	["?"] = ",",
	["~"] = "Ё",
}

---Посчитать РУ-дубль lhs. Возвращает nil, если дубль не нужен/совпадает.
---@param lhs string
---@return string|nil
function M.ru_lhs(lhs)
	if type(lhs) ~= "string" or lhs == "" then
		return nil
	end
	-- Служебные последовательности не трогаем.
	if lhs:find("Plug", 1, true) or lhs:find("SID", 1, true) then
		return nil
	end
	local out = {}
	local changed = false
	local i = 1
	local n = #lhs
	while i <= n do
		local ch = lhs:sub(i, i)
		if ch == "<" then
			local j = lhs:find(">", i, true)
			if not j then
				-- Битый "<" без закрытия — транслитерируем остаток посимвольно.
				for k = i, n do
					local c = lhs:sub(k, k)
					local rc = en_to_ru[c]
					if rc then
						changed = true
						out[#out + 1] = rc
					else
						out[#out + 1] = c
					end
				end
				break
			end
			local inner = lhs:sub(i + 1, j - 1)
			-- Модификаторные блоки <C-x>/<A-x>/<M-x>/<D-x> (в т.ч. <C-S-x>):
			-- транслитерируем одиночный хвост после последнего "-".
			-- <leader>/<CR>/<Esc>/<Tab>/<S-Tab> и т.п. — хвост длинный, пропускаем.
			local tail = inner:match("%-([^-]+)$")
			if tail and #tail == 1 and en_to_ru[tail] then
				local prefix = inner:sub(1, #inner - 1)
				if
					prefix:match("^[CcAaMmDdSs%s%-]+$")
					and (prefix:find("[Cc]%s*%-") or prefix:find("[Aa]%s*%-") or prefix:find("[Mm]%s*%-") or prefix:find(
						"[Dd]%s*%-"
					))
				then
					out[#out + 1] = "<" .. prefix .. en_to_ru[tail] .. ">"
					changed = true
				else
					out[#out + 1] = lhs:sub(i, j)
				end
			else
				out[#out + 1] = lhs:sub(i, j)
			end
			i = j + 1
		else
			local rc = en_to_ru[ch]
			if rc then
				changed = true
				out[#out + 1] = rc
			else
				out[#out + 1] = ch
			end
			i = i + 1
		end
	end
	if not changed then
		return nil
	end
	local res = table.concat(out)
	if res == lhs then
		return nil
	end
	return res
end

---Нужно ли дублировать для этих мод (защита русского ввода в insert/cmdline).
---@param mode string|table
---@param lhs string
---@return boolean
local function should_dup(mode, lhs)
	-- Одиночный печатный символ в insert/cmdline — это текст (",", ".", ";"),
	-- а не хоткей: дубль сломал бы печать ("б" вместо ",").
	if type(lhs) == "string" and not lhs:find("<", 1, true) and #lhs == 1 then
		local modes = type(mode) == "table" and mode or { mode }
		for _, m in ipairs(modes) do
			if m == "i" or m == "c" then
				return false
			end
		end
	end
	return true
end

---Обернуть vim.keymap.set + api-варианты. Повторный вызов — no-op.
function M.setup()
	if _G._ru_keymap_wrapped then
		return
	end
	_G._ru_keymap_wrapped = true

	local orig_set = vim.keymap.set
	---@diagnostic disable-next-line: duplicate-set-field
	vim.keymap.set = function(mode, lhs, rhs, opts)
		local ret = orig_set(mode, lhs, rhs, opts)
		if type(lhs) == "string" and should_dup(mode, lhs) then
			local ru = M.ru_lhs(lhs)
			if ru then
				pcall(orig_set, mode, ru, rhs, opts)
			end
		end
		return ret
	end

	local orig_api = vim.api.nvim_set_keymap
	---@diagnostic disable-next-line: duplicate-set-field
	vim.api.nvim_set_keymap = function(mode, lhs, rhs, opts)
		orig_api(mode, lhs, rhs, opts)
		if type(lhs) == "string" and should_dup(mode, lhs) then
			local ru = M.ru_lhs(lhs)
			if ru then
				pcall(orig_api, mode, ru, rhs, opts)
			end
		end
	end

	local orig_buf = vim.api.nvim_buf_set_keymap
	---@diagnostic disable-next-line: duplicate-set-field
	vim.api.nvim_buf_set_keymap = function(buf, mode, lhs, rhs, opts)
		orig_buf(buf, mode, lhs, rhs, opts)
		if type(lhs) == "string" and should_dup(mode, lhs) then
			local ru = M.ru_lhs(lhs)
			if ru then
				pcall(orig_buf, buf, mode, ru, rhs, opts)
			end
		end
	end
end

return M
