-- dev.agentmine — в сессии ревью агента ваши правки, сделанные ДО её старта, видны на полях
-- серым `╎`, а правки агента — как обычно знаками gitsigns (база gitsigns = база сессии).
--
-- Почему свой: gitsigns держит одну базу, и с базой сессии ваши незакоммиченные правки
-- исчезают с полей целиком. Номера строк из `git diff HEAD <base>` не годятся — агент
-- сдвигает строки. Считаем в координатах буфера: «изменено от HEAD» минус «изменено от
-- базы» = ваше (dev.fx.changed_rows). Два `git show` на файл за сессию, дальше — память.

local M = {}

local ns = vim.api.nvim_create_namespace("dev_agentmine")
local DEBOUNCE_MS = 300
local session = nil -- { root, base }
local texts = {} -- путь от корня -> { head = string[]?, base = string[]? } | "pending"
local timers = {} -- buf -> uv timer

--- Строки буфера, которые вы меняли до сессии и агент с тех пор не трогал. Чистая.
---@param head string[] файл в HEAD ({} — новый файл)
---@param base string[] файл в базе сессии
---@param cur string[] текущий текст буфера
---@return integer[] строки (0-based)
function M._mine(head, base, cur)
	local fx = require("dev.fx")
	local agent = {}
	for _, r in ipairs(fx.changed_rows(base, cur)) do
		agent[r] = true
	end
	local out = {}
	for _, r in ipairs(fx.changed_rows(head, cur)) do
		if not agent[r] then
			out[#out + 1] = r
		end
	end
	return out
end

local function render(buf, t)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for _, r in ipairs(M._mine(t.head, t.base, cur)) do
		if r < #cur then
			-- priority ниже gitsigns (6): на строке, где правил и агент, знак агента главнее.
			vim.api.nvim_buf_set_extmark(buf, ns, r, 0, { sign_text = "╎", sign_hl_group = "Comment", priority = 5 })
		end
	end
end

local function show(root, rev, rel, cb)
	vim.system({ "git", "-C", root, "show", rev .. ":" .. rel }, { text = true }, function(o)
		vim.schedule(function()
			cb(o.code == 0 and vim.split(o.stdout, "\n", { plain = true }) or nil)
		end)
	end)
end

--- Пересчитать знаки буфера (текст HEAD/базы — из памяти, первый раз — асинхронно из git).
function M.refresh(buf)
	local s = session
	if not s or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
		return
	end
	local name = vim.api.nvim_buf_get_name(buf)
	if name:sub(1, #s.root + 1) ~= s.root .. "/" then
		return
	end
	local rel = name:sub(#s.root + 2)
	local t = texts[rel]
	if t == "pending" then
		return
	elseif t then
		return t.base and render(buf, t)
	end
	texts[rel] = "pending"
	show(s.root, "HEAD", rel, function(head)
		show(s.root, s.base, rel, function(base)
			if session ~= s then
				return
			end
			-- В базе файла нет (был untracked до старта, stash create его не берёт) — не знаем, чьё.
			t = { head = (head or {}), base = base }
			-- git show даёт хвостовой \n -> пустой последний элемент; у буфера его нет.
			for _, l in ipairs({ t.head, t.base or {} }) do
				if l[#l] == "" then
					l[#l] = nil
				end
			end
			texts[rel] = t
			if t.base then
				render(buf, t)
			end
		end)
	end)
end

local function schedule(buf)
	local tm = timers[buf] or vim.uv.new_timer()
	timers[buf] = tm
	tm:stop()
	tm:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
		M.refresh(buf)
	end))
end

---@param s {root: string, base: string}
function M.start(s)
	M.stop()
	session = { root = s.root, base = s.base }
	local grp = vim.api.nvim_create_augroup("DevAgentMine", { clear = true })
	vim.api.nvim_create_autocmd({ "BufWinEnter", "TextChanged", "InsertLeave", "FileChangedShellPost" }, {
		group = grp,
		desc = "agent: your pre-session edits on the gutter",
		callback = function(a)
			schedule(a.buf)
		end,
	})
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		M.refresh(vim.api.nvim_win_get_buf(w))
	end
end

function M.stop()
	pcall(vim.api.nvim_del_augroup_by_name, "DevAgentMine")
	for _, tm in pairs(timers) do
		tm:stop()
		tm:close()
	end
	timers, texts, session = {}, {}, nil
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
			vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
		end
	end
end

return M
