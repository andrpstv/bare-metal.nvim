-- Гард termguicolors для «тупых» терминалов.
--
-- Вынесен в отдельный модуль, потому что включать 24-битный цвет умеет не только
-- начальная загрузка конфига: black-metal делает `vim.o.termguicolors = true`
-- внутри load() (pack/.../lua/black-metal/init.lua:33), а load() вызывается
-- ДВАЖДЫ — на базовой теме и ещё раз на кастомной. Поэтому гард обязан
-- отрабатывать после КАЖДОГО вызова темы, а не «после colorscheme»: при
-- отложенной теме (settings.defer_theme) событие ColorScheme уже отыграло, а
-- кастомный проход приедет позже и снова включит 24-битный режим.
--
-- Идемпотентен: повторный вызов безвреден, на нормальном терминале — no-op.
--
-- ПОКРЫТИЕ ТОЛЬКО ЭТО, и это надо знать (проверено замерами):
--   TERM=dumb             -> выключает termguicolors
--   NO_COLOR=1            -> выключает
--   TERM=screen*          -> выключает (screen, screen-256color)
--   TERM=tmux-256color    -> НЕ выключает: гард молчит, termguicolors остаётся true
-- Совпадение `^screen` покрывает tmux только когда tmemux внутри себя выставил
-- TERM=screen-*. При обычном default-terminal=tmux-256color ветка не срабатывает.
-- Это ДОСТАВШАЯСЯ ПО НАСЛЕДСТВУ дыра, а не регрессия отложенной темы: измерено,
-- что tmux-256color даёт termguicolors=true и при defer_theme=true, и при false —
-- то есть поведение одинаковое в обоих режимах.
-- Почему не расширяем здесь на tmux: у пользователя с tmux, умеющим truecolor
-- (напр. настроенный tc/terminal-overrides), принудительное выключение сломало бы
-- рабочий терминал. Это продуктовое решение — см. находку владельцу в
-- docs/theme-defer-2026-09-25.md.
local M = {}

--- Принудительно выключить termguicolors там, где 24 бита ломают вывод.
--- Покрывает dumb / NO_COLOR / screen* — см. таблицу покрытия в шапке модуля.
function M.enforce()
	local term = vim.env.TERM or ""
	if term == "dumb" or (vim.env.NO_COLOR or "") ~= "" or term:match("^screen") then
		-- Повторно, даже если выглядит уже выключенным: black-metal мог включить
		-- обратно в том же кадре.
		vim.api.nvim_set_option_value("termguicolors", false, {})
	end
end

return M
