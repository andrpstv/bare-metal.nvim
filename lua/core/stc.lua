-- core.stc — кастомная statuscolumn: [знак: 1][номер][гит-бар: 1].
--
-- Почему свой: signcolumn=yes (1 ячейка) прятал знак gitsigns, когда на той же строке есть
-- диагностика. Плагины statuscolumn тащат свои фреймворки; здесь ~80 строк поверх extmarks.
-- Вызывается на каждую видимую строку: один nvim_buf_get_extmarks, без I/O.
-- Тестируется через M.render(win, lnum, relnum, virtnum) с явными аргументами.

local M = {}

local ns_names = {} -- id → имя namespace; безымянные кэшируются как ""

local function ns_name(id)
	local name = ns_names[id]
	if name == nil then
		for n, i in pairs(vim.api.nvim_get_namespaces()) do
			ns_names[i] = n
		end
		name = ns_names[id] or ""
		ns_names[id] = name -- безымянный не перестраивает кэш на каждой строке
	end
	return name
end

local function render_impl(win, lnum, relnum, virtnum)
	local buf = vim.api.nvim_win_get_buf(win)
	if vim.b[buf].large_file then
		return "%l "
	end
	local wo = vim.wo[win]
	local width = 0
	if wo.number or wo.relativenumber then
		-- Компактно: цифр сколько нужно файлу +1 на отступ от знака (numberwidth не берём — съедал экран).
		width = #tostring(vim.api.nvim_buf_line_count(buf)) + 1
	end
	-- Перенос строки: та же ширина, иначе колонка «пляшет».
	if virtnum ~= 0 then
		return string.rep(" ", 1 + width + 1)
	end

	local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { lnum - 1, 0 }, { lnum - 1, -1 }, {
		details = true,
		type = "sign",
	})
	local best, best_prio, git, num_hl = nil, -1, nil, nil
	for _, m in ipairs(marks) do
		local d = m[4]
		if d.number_hl_group and not num_hl then
			num_hl = d.number_hl_group -- numhl диагностики: красный номер у строки с ошибкой
		end
		if d.sign_text then
			if ns_name(d.ns_id):sub(1, 8) == "gitsigns" then
				git = git or d
			elseif (d.priority or 0) > best_prio then
				best, best_prio = d, d.priority or 0
			end
		end
	end

	local out = {}
	-- Знак — одна ячейка: первый символ sign_text («E », «● » → «E», «●»).
	if best then
		out[#out + 1] = "%#" .. (best.sign_hl_group or "SignColumn") .. "#" .. (best.sign_text:match("^[%z\1-\127\194-\244][\128-\191]*") or " "):gsub("%%", "%%%%")
	else
		out[#out + 1] = "%#LineNr# "
	end
	if width > 0 then
		local cur = lnum == vim.api.nvim_win_get_cursor(win)[1]
		local n = (cur or not wo.relativenumber) and lnum or relnum
		local hl = num_hl or (cur and "CursorLineNr" or "LineNr")
		out[#out + 1] = "%#" .. hl .. "#" .. string.format("%" .. width .. "d", n)
	end
	if git then
		out[#out + 1] = "%#" .. (git.sign_hl_group or "SignColumn") .. "#▎"
	elseif vim.fn.foldclosed(lnum) == lnum then
		out[#out + 1] = "%#Folded#›"
	else
		out[#out + 1] = " "
	end
	-- Git-полоса «▎» рисуется у левого края ячейки — сама и есть зазор до кода.
	return table.concat(out) .. "%*"
end

--- Рендер statuscolumn; без аргументов — из контекста (g:statusline_winid и v:lnum/relnum/virtnum).
function M.render(win, lnum, relnum, virtnum)
	if win == nil then
		win, lnum, relnum, virtnum = vim.g.statusline_winid, vim.v.lnum, vim.v.relnum, vim.v.virtnum
	end
	if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
		return ""
	end
	return render_impl(win, lnum, relnum, virtnum)
end

return M
