-- dev.lspwait — спиннер у курсора, пока висит медленный LSP-запрос пользователя (gd, gr, K, rename…).
--
-- Почему свой: на холодном gopls непонятно, принят ли `gd`, — жмут повторно. Встроенное событие
-- LspRequest (pending/complete/cancel) даёт всё нужное; плагины уровня noice ради этого не нужны.
-- Подключение — одна автокоманда в core/event.lua; таймер живёт только пока виден спиннер.

local M = {}

-- Только то, что запускает пользователь. signatureHelp нет: его шлёт подсказка сигнатуры
-- при наборе, спиннер мигал бы во время печати. Фоновые (semanticTokens, inlayHint, …) — мимо.
M.TRACKED = {
	["textDocument/definition"] = true,
	["textDocument/references"] = true,
	["textDocument/hover"] = true,
	["textDocument/implementation"] = true,
	["textDocument/typeDefinition"] = true,
	["textDocument/rename"] = true,
	["textDocument/prepareRename"] = true,
	["textDocument/codeAction"] = true,
	["textDocument/prepareCallHierarchy"] = true,
	["callHierarchy/incomingCalls"] = true,
	["callHierarchy/outgoingCalls"] = true,
	["workspace/symbol"] = true,
}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local DELAY_MS, FRAME_MS, CAP_MS = 150, 80, 30000
local ns = vim.api.nvim_create_namespace("dev_lspwait")

local pending = {} -- buf -> { ["client:request"] = { client_id, t0 } }
local live = {} -- buf -> stop() тикера, или true в статичном режиме

function M._tracked(method)
	return M.TRACKED[method] == true
end

function M._frame(i)
	return FRAMES[(i - 1) % #FRAMES + 1]
end

-- Самый старый живой запрос буфера; потерянные (без complete дольше CAP_MS) выбрасываем.
local function oldest(buf)
	local now, best = vim.uv.now(), nil
	for key, r in pairs(pending[buf] or {}) do
		if now - r.t0 > CAP_MS then
			pending[buf][key] = nil
		elseif not best or r.t0 < best.t0 then
			best = r
		end
	end
	return best
end

local function hide(buf)
	local l = live[buf]
	live[buf] = nil
	if type(l) == "function" then
		l()
	end
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	end
end

-- Метка в конце строки курсора; буфер ушёл из текущего окна — не рисуем, но запрос ждём.
local function draw(buf, text)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	local win = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_get_buf(win) ~= buf then
		return
	end
	local row = vim.api.nvim_win_get_cursor(win)[1] - 1
	vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = { { text, "Comment" } }, virt_text_pos = "eol" })
end

local function label(r)
	local c = vim.lsp.get_client_by_id(r.client_id)
	return c and c.name or "lsp"
end

local function show(buf)
	local r = live[buf] == nil and vim.api.nvim_buf_is_valid(buf) and oldest(buf)
	if not r or vim.uv.now() - r.t0 < DELAY_MS then
		return
	end
	local fx = require("dev.fx")
	if not fx.enabled() then
		live[buf] = true
		draw(buf, "… " .. label(r))
		-- Потерянный complete не оставит метку навсегда.
		vim.defer_fn(function()
			if live[buf] == true and not oldest(buf) then
				hide(buf)
			end
		end, CAP_MS + 100)
		return
	end
	live[buf] = fx.ticker(FRAME_MS, function(i)
		local cur = vim.api.nvim_buf_is_valid(buf) and oldest(buf)
		if not cur then
			hide(buf)
			return false
		end
		draw(buf, M._frame(i) .. " " .. label(cur))
	end)
end

--- Событие LspRequest для отслеживаемого метода (фильтр — в core/event.lua).
---@param rtype "pending"|"complete"|"cancel"
function M.on_request(buf, client_id, request_id, rtype)
	if vim.b[buf].large_file then
		return
	end
	local key = client_id .. ":" .. request_id
	if rtype == "pending" then
		pending[buf] = pending[buf] or {}
		pending[buf][key] = { client_id = client_id, t0 = vim.uv.now() }
		vim.defer_fn(function()
			show(buf)
		end, DELAY_MS)
		return
	end
	if pending[buf] then
		pending[buf][key] = nil
		if not oldest(buf) then
			pending[buf] = nil
			hide(buf)
		end
	end
end

return M
