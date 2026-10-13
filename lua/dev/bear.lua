-- dev.bear — медведь статуслайна живёт: занят (go test/build), успех/провал,
-- «ого» на внешнюю правку, сон после простоя. Хвост морды — ASCII-кадры.
--
-- Почему свой: морда — часть своего статуслайна (keymap/statusline.lua). Статуслайн
-- читает M.text() через package.loaded, поэтому пока медведь никому не понадобился,
-- модуль не загружен и работы ноль. Таймер есть только пока играет состояние.

local M = {}

local fx = require("dev.fx")

-- frames — хвост по кадрам одной ширины (иначе статуслайн дёргается); loops — сколько
-- проигрышей до заморозки на последнем кадре (nil — пока не снимут); still — хвост
-- без анимаций; ttl — сколько живёт состояние, мс (nil — до снятия).
M.STATES = {
	busy = { face = "ʕ ·ᴥ· ʔ", frames = { "|", "/", "-", "\\" }, still = "~", ms = 120, ttl = 15 * 60 * 1000 },
	pass = { face = "ʕ ᵔᴥᵔ ʔ", frames = { ".", "+", "*", "+", "*" }, loops = 1, still = "*", ms = 120, ttl = 3000 },
	fail = { face = "ʕ ಠᴥಠ ʔ", frames = { "!", " ", "!", " ", "!" }, loops = 1, still = "!", ms = 180, ttl = 5000 },
	wow = { face = "ʕ OᴥO ʔ", frames = { "! ", "!!", "! ", "!!" }, loops = 1, still = "!", ms = 150, ttl = 1500 },
	sleep = { face = "ʕ -ᴥ- ʔ", frames = { "z  ", "zZ ", "zZz" }, loops = 10, still = "z", ms = 700 },
}

local busy = {} -- key -> true: что сейчас крутит спиннер (test, go)
local cur = nil -- { name, i, stop, gen }
local gen = 0

local function redraw()
	pcall(vim.cmd, "redrawstatus")
end

local function clear()
	if cur and cur.stop then
		cur.stop()
	end
	cur = nil
end

local function show(name)
	clear()
	gen = gen + 1
	local st = M.STATES[name]
	local me = { name = name, gen = gen }
	cur = me
	if fx.enabled() then
		local last = st.loops and st.loops * #st.frames
		me.stop = fx.ticker(st.ms, function(i)
			if cur ~= me then
				return false
			end
			me.i = last and math.min(i, last) or i
			redraw()
			if last and i >= last then
				return false
			end
		end)
	end
	if st.ttl then
		vim.defer_fn(function()
			if cur and cur.gen == me.gen then
				clear()
				-- Флеш результата прошёл, а что-то ещё крутится — назад к спиннеру.
				if next(busy) then
					show("busy")
				end
				redraw()
			end
		end, st.ttl)
	end
	redraw()
end

--- Морда с хвостом вместо обычной, или nil — тогда статуслайн рисует морду режима.
---@return string?
function M.text()
	if not cur then
		return nil
	end
	local st = M.STATES[cur.name]
	local tail = cur.i and st.frames[(cur.i - 1) % #st.frames + 1] or st.still
	return st.face .. tail
end

--- Текущее состояние (для тестов и статуслайна); nil — медведь просто следит за режимом.
function M.state()
	return cur and cur.name
end

--- Началась долгая работа key (go test, go build): спиннер, пока не придёт done.
---@param key string
function M.busy(key)
	busy[key] = true
	if not cur or cur.name ~= "busy" then
		show("busy")
	end
end

--- Работа key кончилась: флеш успеха/провала; если крутится ещё что-то — спиннер остаётся.
---@param key string
---@param ok boolean
function M.done(key, ok)
	busy[key] = nil
	if next(busy) then
		return
	end
	show(ok and "pass" or "fail")
end

--- Внешняя правка в видимом буфере (агент, git checkout). Спиннер не перебивает.
function M.wow()
	if not next(busy) then
		show("wow")
	end
end

--- Простой: засыпает, только если ничего не показывает.
function M.sleep()
	if not cur then
		show("sleep")
	end
end

function M.sleeping()
	return cur ~= nil and cur.name == "sleep"
end

function M.wake()
	if M.sleeping() then
		clear()
		redraw()
	end
end

return M
