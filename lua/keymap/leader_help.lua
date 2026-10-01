-- keymap/leader_help — подсказка по leader-сочетаниям.
--
-- Зачем: в конфиге больше сотни хоткеев, а which-key есть только в каталоге
-- и не установлен — потребитель после установки не видит ни одного из них,
-- пока не откроет исходники. Своя подсказка обходится без новой зависимости
-- и не ломает главное свойство дистрибутива: всё вендорено в репозитории,
-- ничего не тянется из сети.
--
-- Как устроено (модель — which-key `delay`, билтин):
--   * индекс строится из ЖИВЫХ маппингов (nvim_get_keymap + nvim_buf_get_keymap),
--     а не из продублированной вручную таблицы — разойтись с кодом не может;
--   * vim.on_key только наблюдает и ничего не перехватывает; сам <leader> не
--     замаплен, поэтому нажатие не ждёт timeoutlen (конфиг явно от этого уходит,
--     см. keymap/init.lua про <leader>eX);
--   * <leader> лишь ВЗВОДИТ показ: подсказка всплывает через leader_help_delay_ms
--     (по умолч. 3000) и только если до тех пор не нажата другая клавиша —
--     быстро допечатал сочетание — ничего не мигает (как which-key delay,
--     независимо от timeoutlen);
--   * любая следующая клавиша гасит и взведённый показ, и открытую подсказку:
--     сочетание либо дописано, либо отменено — хинт свою работу сделал;
--   * страховочный авто-закрыватель IDLE_MS прибирает забытое окно.
--
-- ВАЖНО, про fast events. Колбэк vim.on_key выполняется в контексте, где
-- запрещены vim.api, vim.fn и io: любое такое обращение бросает ошибку, а
-- Neovim по контракту УДАЛЯЕТ колбэк после первой ошибки — подсказка молча
-- перестаёт работать до перезапуска. Поэтому колбэк трогает только строки
-- и локальное состояние (state.* — plain Lua, в fast event безопасно),
-- а всё, что требует API, выполняется в vim.schedule. Наблюдение —
-- дёшевое, планирование вынесено с горячего пути: schedule дёргаем только
-- когда есть что взвести/гасить, а не на каждую клавишу.

local M = {}

local LEADER = " "
local IDLE_MS = 2500

local index = nil
local state = {
	win = nil,
	buf = nil,
	timer = nil,
	show_timer = nil,
	shown = false,
}

--- Пауза до показа. Читается при каждом взводе: require кэширован,
--- смена настройки применяется без рестарта.
-- Forward: arm() (ниже) планирует apply() через таймер, а определён
-- apply() позже по файлу — без этого arm видел бы глобальный nil.
local apply

--- Маппинги, начинающиеся с leader: глобальные + текущего буфера.
--- Буферные нужны для LSP-сочетаний (<leader>li, <leader>rn), которые вешаются
--- на LspAttach и в глобальной таблице отсутствуют.
local function collect()
	local out, seen = {}, {}
	local function take(list)
		for _, m in ipairs(list) do
			local lhs = m.lhs or ""
			-- leader хранится литеральным пробелом: nvim_get_keymap отдаёт " ff",
			-- а не "<Space>ff" — проверено на живом рантайме.
			if #lhs > 1 and lhs:sub(1, 1) == LEADER and not seen[lhs] then
				seen[lhs] = true
				out[#out + 1] = { lhs = lhs, desc = m.desc or "" }
			end
		end
	end
	take(vim.api.nvim_get_keymap("n"))
	pcall(take, vim.api.nvim_buf_get_keymap(0, "n"))
	-- v/x тоже: иначе visual-версии (<leader>fs-grep и др.) невидимы.
	-- Режим дописываем суффиксом, чтобы n/v-тёзки не сливались.
	for _, mode in ipairs({ "v", "x" }) do
		for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
			local lhs = m.lhs or ""
			if #lhs > 1 and lhs:sub(1, 1) == LEADER and not seen[lhs .. mode] then
				seen[lhs .. mode] = true
				out[#out + 1] = { lhs = lhs .. " [" .. mode .. "]", desc = m.desc or "" }
			end
		end
		pcall(function()
			for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, mode)) do
				local lhs = m.lhs or ""
				if #lhs > 1 and lhs:sub(1, 1) == LEADER and not seen[lhs .. mode] then
					seen[lhs .. mode] = true
					out[#out + 1] = { lhs = lhs .. " [" .. mode .. "]", desc = m.desc or "" }
				end
			end
		end)
	end
	return out
end

local function idx()
	if not index then
		index = collect()
	end
	return index
end

--- Сбросить индекс: буферные LSP-хоткеи появляются на LspAttach, то есть уже
--- после старта, и в первый снимок не попадают.
function M.invalidate()
	index = nil
end

local function exact(prefix)
	for _, m in ipairs(idx()) do
		if m.lhs == prefix then
			return true
		end
	end
	return false
end

--- Продолжения, сгруппированные по ПЕРВОЙ букве.
---
--- Без группировки нажатие <leader> выдавало все 49 сочетаний целиком, и список
--- не влезал в экран. Здесь сначала по пункту на букву («f — поиск»), и только
--- после нажатия f раскрываются ff/fb/fp.
local function group(prefix)
	local order, bychar = {}, {}
	for _, m in ipairs(idx()) do
		local lhs = m.lhs
		if #lhs > #prefix and lhs:sub(1, #prefix) == prefix then
			local c = lhs:sub(#prefix + 1, #prefix + 1)
			local g = bychar[c]
			if not g then
				g = { descs = {}, seen = {}, deeper = false, direct = nil }
				bychar[c] = g
				order[#order + 1] = c
			end
			local d = m.desc
			if d and d ~= "" and not g.seen[d] then
				g.seen[d] = true
				g.descs[#g.descs + 1] = d
			end
			if #lhs == #prefix + 1 then
				g.direct = d
			else
				g.deeper = true
			end
		end
	end

	local out = {}
	for _, c in ipairs(order) do
		local g = bychar[c]
		local desc
		if g.direct and not g.deeper then
			desc = g.direct
		else
			desc = table.concat(g.descs, ", ")
			if g.deeper and #g.descs == 0 then
				desc = "more…"
			end
		end
		if #desc > 58 then
			desc = desc:sub(1, 55) .. "…"
		end
		out[#out + 1] = { key = "<leader>" .. c, desc = desc }
	end
	return out
end

local function close()
	state.shown = false
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	state.win = nil
	state.buf = nil
	if state.timer then
		state.timer:stop()
		state.timer:close()
		state.timer = nil
	end
	if state.show_timer then
		state.show_timer:stop()
		state.show_timer:close()
		state.show_timer = nil
	end
end

local function render(items)
	if #items == 0 then
		close()
		return
	end
	local avail = math.max(4, vim.o.lines - 6)
	local lines, shown = {}, 0
	local width = 0
	for _, it in ipairs(items) do
		if shown >= avail then
			break
		end
		local text = string.format(" %-12s %s", it.key, it.desc)
		lines[#lines + 1] = text
		shown = shown + 1
		if #text > width then
			width = #text
		end
	end
	if #items > shown then
		-- Список не влез: говорим об этом, иначе он молча выглядит полным.
		lines[shown] = string.format(" %-12s … %d more", "", #items - shown)
	end

	if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
		state.buf = vim.api.nvim_create_buf(false, true)
		vim.bo[state.buf].bufhidden = "wipe"
	end
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	local ns = vim.api.nvim_create_namespace("distro_leader_help")
	vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
	for i = 1, #lines do
		pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, "Title", i - 1, 0, #lines[i])
	end

	local w = math.min(width, math.max(20, vim.o.columns - 4))
	if not state.win or not vim.api.nvim_win_is_valid(state.win) then
		local ok, win = pcall(vim.api.nvim_open_win, state.buf, false, {
			relative = "editor",
			row = 0,
			col = math.max(0, vim.o.columns - w - 1),
			width = w,
			height = #lines,
			style = "minimal",
			border = "rounded",
			zindex = 60,
			noautocmd = true,
		})
		if not ok then
			state.buf = nil
			return
		end
		state.win = win
		vim.wo[state.win].wrap = false
	else
		pcall(vim.api.nvim_win_set_config, state.win, {
			relative = "editor",
			row = 0,
			col = math.max(0, vim.o.columns - w - 1),
			width = w,
			height = #lines,
		})
	end
	state.shown = true
end

--- Взвести показ: <leader> нажат, ждём leader_help_delay_ms.
--- Если до срабатывания придёт любая другая клавиша — cancel() снимет взвод.
--- Вызывается из vim.schedule (здесь API можно).
local function arm()
	if state.shown then
		-- Уже висит (пользователь снова нажал <leader>): висит и висит,
		-- приберёт либо следующая клавиша, либо страховочный IDLE_MS.
		return
	end
	if state.show_timer then
		state.show_timer:stop()
		state.show_timer:close()
		state.show_timer = nil
	end
	local ok_s, settings = pcall(require, "core.settings")
	local delay = ok_s and tonumber(settings.leader_help_delay_ms) or 3000
	if not delay or delay < 0 then
		delay = 3000
	end
	state.show_timer = vim.uv.new_timer()
	state.show_timer:start(delay, 0, function()
		vim.schedule(apply)
	end)
end

--- Показать подсказку. Вызывается из vim.schedule — либо сразу (не используется
--- напрямую), либо срабатыванием show_timer через leader_help_delay_ms после
--- <leader>. Проверяет режим: если пользователь ушёл из normal (или дописал
--- сочетание быстрее таймера, а cancel по гонке не успел) — молча гасимся.
apply = function()
	local m = vim.fn.mode()
	if m ~= "n" and m ~= "no" then
		close()
		return
	end
	-- Сочетание дописано: закрываемся ДО того, как выполнится сама команда.
	local items = group(LEADER)
	if #items == 0 then
		close()
		return
	end
	render(items)
	if state.timer then
		return
	end
	state.timer = vim.uv.new_timer()
	state.timer:start(IDLE_MS, 0, function()
		vim.schedule(close)
	end)
end

--- Полный перечень leader-сочетаний текстом.
--- Всплывающая подсказка показывает верхний уровень; посмотреть полный
--- список, который не влезает в экран, можно этой командой.
function M.list()
	M.invalidate()
	local items = {}
	for _, m in ipairs(collect()) do
		items[#items + 1] = string.format("  <leader>%s  %s", m.lhs:sub(2), m.desc)
	end
	table.sort(items)
	vim.notify(table.concat(items, "\n"), vim.log.levels.INFO, { title = "leader keymaps" })
end

--- Подключить наблюдателя. Повторные вызовы безопасны.
function M.setup()
	if M._installed then
		return
	end
	M._installed = true

	-- Без UI показывать некуда, а в --headless и нажимать нечего.
	if #vim.api.nvim_list_uis() == 0 then
		return
	end
	-- Команда-справочник регистрируется ДО проверки leader_help: полный
	-- перечень нужен и тогда, когда всплывающая подсказка выключена.
	vim.api.nvim_create_user_command("LeaderHelp", function()
		M.list()
	end, { desc = "list every leader keymap and its description" })

	if require("core.settings").leader_help == false then
		return
	end

	local ns = vim.api.nvim_create_namespace("distro_leader_help")

	-- ПОЧЕМУ ТОЛЬКО ПЕРВЫЙ УРОВЕНЬ. Наблюдатель ловит лишь первое нажатие:
	-- пока висит незавершённое mapping-последовательность («<leader>» ждёт
	-- продолжения), Neovim не возвращается в цикл ввода и колбэк на
	-- следующий символ НЕ вызывается. Проверено на живом стенде: лог
	-- колбэка за <leader>+f содержит ровно один элемент — пробел.
	--
	-- Углубление («<leader>» -> f -> ff/fb/fp) требует маппинга на каждую
	-- первую букву. Конфиг сознательно этого избегает: см. keymap/init.lua,
	-- где <leader>e и <leader>g вынесены из-под ожидания timeoutlen именно
	-- потому, что любой маппинг на <leader>eX заставляет ждать. Платить этим
	-- ради подсказки — неправильный размен: сочетания у потребителя важнее.
	--
	-- Поэтому показываем верхний уровень целиком. Он умещается в экран
	-- (16 групп) и отвечает на вопрос «что вообще есть», а полный перечень —
	-- в :LeaderHelp.
	vim.on_key(function(key)
		-- FAST EVENT: здесь нельзя трогать ни vim.api, ни vim.fn, ни io.
		-- Только сравнение строк и чтение state.* (plain Lua); всё остальное
		-- отложено на главный цикл. schedule дёргаем только когда есть что
		-- взвести/гасить: на каждую «пустую» клавишу — ноль работы.
		if key == LEADER then
			vim.schedule(arm)
		elseif key == "<Esc>" or key == "<C-c>" or key == "<C-[>" then
			vim.schedule(close)
		elseif state.show_timer ~= nil or state.shown then
			-- Продолжение сочетания или аборт: взвод снять, окно закрыть.
			vim.schedule(close)
		end
		-- В Neovim 0.11 сигнатура именно (fn, ns_id, opts): ns_id — ВТОРОЙ
		-- позиционный аргумент. Передача options на его место роняет init.lua
		-- с E5113 «ns_id: expected number, got table».
	end, ns, { noremap = true })
end

return M
