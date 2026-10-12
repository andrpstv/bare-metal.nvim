-- dev.agent — сессия ревью правок CLI-агента: что поменялось с момента старта.
--
-- Почему свой: окно агента и отправку контекста даёт sidekick.nvim, а обзора
-- «что агент сделал за сессию» нет ни в одном из просмотренных плагинов
-- (docs/distro/34-agent-workflow.md). Работает по файлам и git — одинаково
-- для любого агента.
--
-- База сессии — `git stash create`: коммит-снимок рабочего дерева вместе с
-- вашими незакоммиченными правками; НЕ трогает ни дерево, ни индекс, ни список
-- stash. Чистое дерево → HEAD. Относительно базы:
--   * gitsigns.change_base(base, true) — знаки показывают только новые правки;
--   * quickfix — ханки `git diff -U0 <base>` + новые untracked-файлы;
--   * Diffview <base> — полный дифф сессии.
-- Принять/откатить ханк — обычные <leader>gs / <leader>gr. Сами git только читаем.
-- shortcut: файл, бывший untracked до старта и потом изменённый агентом, в обзор
-- не попадает (stash create не снимает untracked); апгрейд — класть их в базу.

local M = {}

---@type {root:string, base:string, untracked:table<string,boolean>}?
M.session = nil

local WARN = vim.log.levels.WARN

local function notify(msg, level)
	vim.notify("[agent] " .. msg, level or vim.log.levels.INFO, { title = "agent" })
end

--- git в корне репозитория; колбэк — в main loop.
local function git(root, args, cb)
	local argv = { "git", "-C", root, "-c", "core.quotepath=off" }
	vim.list_extend(argv, args)
	vim.system(argv, { text = true }, function(obj)
		vim.schedule(function()
			cb(obj.code == 0, obj.stdout or "", obj.stderr or "")
		end)
	end)
end

local function untracked_set(out)
	local set = {}
	for _, p in ipairs(vim.split(out, "\0", { plain = true, trimempty = true })) do
		set[p] = true
	end
	return set
end

local function gitsigns_base(base)
	if require("distro.loader").load("gitsigns.nvim") then
		pcall(function()
			require("gitsigns").change_base(base, true)
		end)
	end
end

--- Начать сессию (или сбросить базу на «сейчас» — «всё принял»).
---@param opts? {quiet?: boolean} quiet: автостарт при открытии агента — вне git молчим
function M.start(opts)
	opts = opts or {}
	local function say(msg)
		if not opts.quiet then
			notify(msg, WARN)
		end
	end
	if vim.fn.executable("git") ~= 1 then
		return say("git not found — the review session needs git")
	end
	-- Сброс — в репозитории текущей сессии: его жмут и из quickfix/окна агента,
	-- где «текущий буфер» не указывает на проект.
	local from = M.session and M.session.root or require("dev.project").root()
	git(from, { "rev-parse", "--show-toplevel" }, function(ok, out)
		if not ok then
			return say("not a git repository — the review session needs git")
		end
		local root = vim.fs.normalize(vim.trim(out))
		local function with_base(base)
			git(root, { "ls-files", "--others", "--exclude-standard", "-z" }, function(_, files)
				local reset = M.session ~= nil
				M.session = { root = root, base = base, untracked = untracked_set(files) }
				gitsigns_base(base)
				notify(
					(reset and "review base reset to now (" or "review session started (")
						.. base:sub(1, 7)
						.. ") — <leader>Aq lists changes since then"
				)
			end)
		end
		git(root, { "stash", "create" }, function(ok_s, sha)
			sha = vim.trim(sha)
			if ok_s and sha ~= "" then
				return with_base(sha)
			end
			git(root, { "rev-parse", "HEAD" }, function(ok_h, head)
				if not ok_h then
					return notify("repository has no commits yet — commit once to start a review session", WARN)
				end
				with_base(vim.trim(head))
			end)
		end)
	end)
end

--- Автостарт при открытии окна агента: идемпотентно, вне git — тихо.
function M.ensure()
	if not M.session then
		M.start({ quiet = true })
	end
end

function M.stop()
	if not M.session then
		return notify("no review session", WARN)
	end
	M.session = nil
	gitsigns_base(nil)
	notify("review session ended — git signs compare with the index again")
end

--- Ханки `git diff -U0 --no-renames` → элементы quickfix. Чистая функция.
---@param out string
---@param root string
---@return table[]
function M._parse_diff(out, root)
	local items, file, old = {}, nil, nil
	local rem, hinted = 0, true -- rem: строк текущего ханка впереди (с -U0 контекста нет)
	for line in vim.gsplit(out, "\n", { plain = true }) do
		local c = line:sub(1, 1)
		if rem > 0 and (c == "+" or c == "-") then
			rem = rem - 1
			if c == "+" and not hinted then
				hinted = true
				items[#items].text = items[#items].text .. ": " .. vim.trim(line:sub(2))
			end
		elseif line:sub(1, 11) == "diff --git " then
			file, old, rem = nil, nil, 0
		elseif line:sub(1, 6) == "--- a/" then
			old = line:sub(7)
		elseif line == "+++ /dev/null" then
			items[#items + 1] = { filename = vim.fs.joinpath(root, old or "?"), lnum = 1, text = "deleted file" }
		elseif line:sub(1, 6) == "+++ b/" then
			file = vim.fs.joinpath(root, line:sub(7))
		elseif line:match("^Binary files ") then
			local p = line:match(" and b/(.+) differ$") or line:match("^Binary files a/(.+) and /dev/null differ$")
			if p then
				items[#items + 1] = { filename = vim.fs.joinpath(root, p), lnum = 1, text = "binary file changed" }
			end
		elseif file then
			local o_start, o_cnt, n_start, n_cnt = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
			if o_start then
				local oc, nc = tonumber(o_cnt) or 1, tonumber(n_cnt) or 1
				local kind = oc == 0 and "added" or (nc == 0 and "removed" or "changed")
				items[#items + 1] = {
					filename = file,
					lnum = math.max(tonumber(n_start), 1),
					text = ("%s (-%d +%d)"):format(kind, oc, nc),
				}
				rem, hinted = oc + nc, nc == 0
			end
		end
	end
	return items
end

--- Все изменения с начала сессии → quickfix.
function M.quickfix()
	local s = M.session
	if not s then
		return notify("no review session — <leader>Ab starts one", WARN)
	end
	git(s.root, { "diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", s.base }, function(ok, out, err)
		if not ok then
			return notify("git diff failed: " .. vim.trim(err):sub(1, 200), vim.log.levels.ERROR)
		end
		local items = M._parse_diff(out, s.root)
		git(s.root, { "ls-files", "--others", "--exclude-standard", "-z" }, function(_, files)
			local new = {}
			for p in pairs(untracked_set(files)) do
				if not s.untracked[p] then
					new[#new + 1] = p
				end
			end
			table.sort(new)
			for _, p in ipairs(new) do
				items[#items + 1] = { filename = vim.fs.joinpath(s.root, p), lnum = 1, text = "new file" }
			end
			vim.fn.setqflist({}, " ", { title = "agent: changes since " .. s.base:sub(1, 7), items = items })
			if #items == 0 then
				pcall(vim.cmd, "cclose")
				return notify("no changes since the session started")
			end
			vim.cmd("copen")
		end)
	end)
end

--- Полный дифф сессии в Diffview.
function M.diffview()
	local s = M.session
	if not s then
		return notify("no review session — <leader>Ab starts one", WARN)
	end
	if require("distro.loader").load("diffview.nvim") then
		vim.cmd({ cmd = "DiffviewOpen", args = { s.base, "-C" .. s.root } })
	end
end

return M
