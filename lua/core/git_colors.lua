-- Синхронизация git/lazygit цветов diff — ОПЦИОНАЛЬНАЯ ФИЧА (sync_git_colors).
--
-- Весь код живёт здесь, чтобы фичу можно было выпилить одним коммитом:
-- удалить lua/core/git_colors.lua и 4 строки вызова в lua/core/init.lua.
-- Больше нигде на неё нет ссылок.
--
-- Поведение: если в ~/.gitconfig нет секции [color "diff"] — дописать её;
-- если нет lazygit-темы — создать config.yml. Обе операции идемпотентны.
--
-- ЗАЩИТА ОТ ГОНКИ. Наивный «прочитал → не нашёл → дописал» даёт дубли при
-- параллельном старте двух nvim: оба читают ДО чтения другим, оба дописывают.
-- Отложенный вызов это усугубляет (окно шире, чем при синхронной записи).
-- Решение — mkdir-лок вокруг всего блока «прочитал-проверил-записал»:
--   * mkdir атомарен и на POSIX, и на Windows (fs_mkdir провалится, если есть);
--   * запись — ИМЕННО APPEND (io.open(gitconfig, "a")), а не atomic-replace:
--     .gitconfig — файл ЧУЖОЙ, пользовательский. Если это симлинк в
--     dotfile-репозиторий, tmp+fsync+rename подменил бы сам симлинк обычным
--     файлом — человек молча потерял бы свою схему, и правки пользователя между
--     чтением и rename пропали бы. append идёт по симлинку и ничего не заменяет;
--     целостность обеспечивает лок вокруг блока, а не атомарность записи файла.
--   * ожидание лока ограничено LOCK_WAIT_MS, устаревший лок (старше
--     LOCK_STALE_MS) снимается — зависший держатель не блокирует старт;
--   * если лок взять не удалось — синхронизация ПРОПУСКАЕТСЯ, а не падает.
--     Это безопасно: лок держит процесс, который делает ровно ту же работу,
--     так что результат всё равно будет записан. Следующий старт доберёт.
local M = {}

local DEFER_MS = 50 -- см. комментарий про первый кадр в docs/opt-2026-09-25-defer.md
local LOCK_WAIT_MS = 250 -- жёсткий предел ожидания лока: старт не блокируется
local LOCK_STALE_MS = 10000 -- лок старше — считаем держатель упавшим
local LOCK_POLL_MS = 5

local settings = require("core.settings")

--------------------------------------------------------------------------------
-- Пути
--------------------------------------------------------------------------------

-- Вызывается НА ГОРЯЧЕМ ПУТИ, до require("core.options"): тот выставляет
-- 'wildignore', а Vim расширяет "~" с его учётом, поэтому ПОСЛЕ него
-- expand("~") может вернуть "" (если $HOME попал под маску, напр. **/tmp/**).
-- Гарды: литерал "$" (пустой env) и пустой путь — иначе путь стал бы
-- "/.gitconfig" и запись ушла бы в корень ФС.
---@return table|nil
function M.resolve_paths()
	local is_windows = vim.fn.has("win32") == 1

	local gitconfig
	if is_windows then
		gitconfig = vim.fn.expand("$USERPROFILE") .. "/.gitconfig"
	else
		gitconfig = vim.fn.expand("~/.gitconfig")
	end
	if gitconfig:match("%$") or gitconfig == "/.gitconfig" or gitconfig == "" then
		return nil
	end

	local lg_dir
	if is_windows then
		lg_dir = vim.fn.expand("$APPDATA") .. "/lazygit"
	else
		lg_dir = vim.fn.expand("~/.config/lazygit")
	end
	if lg_dir:match("%$") or lg_dir == "/lazygit" or lg_dir == "" then
		return nil
	end

	return { gitconfig = gitconfig, lg_dir = lg_dir, lg_config = lg_dir .. "/config.yml" }
end

--------------------------------------------------------------------------------
-- Лок
--------------------------------------------------------------------------------

--- Взять mkdir-лок. @return boolean ok, string|nil held_by_us
local function acquire_lock(lock_dir)
	local waited = 0
	while true do
		if vim.uv.fs_mkdir(lock_dir, 448) then
			return true
		end
		-- существующий лок: устаревший — снимаем
		-- NB: в Neovim 0.10+ mtime приходит таблицей {sec,nsec}, в старых — числом.
		local st = vim.uv.fs_stat(lock_dir)
		if st and type(st.mtime) == "table" then
			local age_ms = os.time() * 1000 - (st.mtime.sec * 1000 + (st.mtime.nsec or 0) / 1000000)
			if age_ms > LOCK_STALE_MS then
				pcall(vim.uv.fs_rmdir, lock_dir)
			end
		end
		if waited >= LOCK_WAIT_MS then
			return false
		end
		vim.uv.sleep(LOCK_POLL_MS)
		waited = waited + LOCK_POLL_MS
	end
end

local function release_lock(lock_dir)
	pcall(vim.uv.fs_rmdir, lock_dir)
end

--------------------------------------------------------------------------------
-- Синхронизация
--------------------------------------------------------------------------------

local function color_snippet(red, green)
	return string.format(
		'\n[color "diff"]\n\told = %s\n\tnew = %s\n\tfuncold = %s\n\tfuncnew = %s',
		red,
		green,
		red,
		green
	)
end

local function lazygit_yaml(red, green)
	return string.format(
		[[os:
  editPreset: "nvim-remote"
gui:
  theme:
    activeBorderColor:
      - "%s"
      - "bold"
    inactiveBorderColor:
      - "#589ed7"
    selectedLineBgColor:
      - "#2d3f76"
    unstagedChangesColor:
      - "%s"
  nerdFontsVersion: "3"
git:
  diff:
    colorAdded: "%s"
    colorModified: "#888888"
    colorRemoved: "%s"
]],
		green,
		red,
		green,
		red
	)
end

---@param paths table
local function sync_locked(paths)
	local green = settings.palette_overwrite.green or "#5f8787"
	local red = settings.palette_overwrite.red or "#974b46"
	local gitconfig = paths.gitconfig

	-- Одноразовая миграция: кэш прежней версии больше не читается.
	pcall(os.remove, paths.lg_dir .. "/.nvim-git-colors.cache")

	-- Проверка и запись — внутри лока, одним критическим сегментом.
	local content = ""
	if vim.fn.filereadable(gitconfig) == 1 then
		local lines = vim.fn.readfile(gitconfig, "b")
		if type(lines) == "table" then
			content = table.concat(lines, "\n")
		end
	end
	if not content:match("%[color \"diff\"%]") then
		-- Именно APPEND, а не atomic-replace (tmp+fsync+rename). Файл ЧУЖОЙ:
		-- ~/.gitconfig часто симлинк в dotfile-репозиторий, и rename заменил бы
		-- симлинк обычным файлом — пользователь молча потерял бы свою схему.
		-- Режим "a" идёт по симлинку и только дописывает. Атомарность замены
		-- из lua/distro/lock.lua тут НЕ применяется осознанно: она годится для
		-- файла, которым владеем мы (distro-lock.json), а не для чужого.
		local f = io.open(gitconfig, "a")
		if f then
			f:write(color_snippet(red, green) .. "\n")
			f:close()
		end
	end

	if vim.fn.isdirectory(paths.lg_dir) == 0 then
		pcall(vim.fn.mkdir, paths.lg_dir, "p")
	end
	if vim.fn.filereadable(paths.lg_config) == 0 then
		-- Тоже обычная запись, не rename: config.yml может быть симлинком.
		local f = io.open(paths.lg_config, "w")
		if f then
			f:write(lazygit_yaml(red, green))
			f:close()
		end
	end
end

---@param paths table|nil
function M.sync(paths)
	if not settings.sync_git_colors or not paths then
		return
	end
	if vim.fn.executable("git") ~= 1 then
		return
	end

	-- Лок живёт рядом с .gitconfig: тот же диск/каталог, тот же $HOME.
	local lock_dir = paths.gitconfig .. ".nvim-colors.lock"
	if not acquire_lock(lock_dir) then
		-- Другой процесс делает ту же работу — пропускаем, он допишет.
		return
	end
	-- pcall: даже падение внутри не должно оставить лок за собой.
	local ok, err = pcall(sync_locked, paths)
	release_lock(lock_dir)
	if not ok then
		pcall(vim.notify, "[core] git color sync failed: " .. tostring(err), vim.log.levels.WARN)
	end
end

--------------------------------------------------------------------------------
-- Отложенный запуск
--------------------------------------------------------------------------------

local pending = false
local timer = nil
local paths_cache = nil

local function run()
	pending = false
	if timer then
		pcall(function()
			timer:stop()
			timer:close()
		end)
		timer = nil
	end
	local p = paths_cache
	paths_cache = nil
	-- pcall: на выходе из сессии ошибка не должна валить :qa
	pcall(M.sync, p)
end

--- Единственная точка входа. Вызывается из core.init (на горячем пути).
function M.schedule()
	if not settings.sync_git_colors or pending then
		return
	end
	paths_cache = M.resolve_paths()
	if not paths_cache then
		return
	end

	-- Headless/скрипты: деферить нечего, нужен детерминированный результат.
	if #vim.api.nvim_list_uis() == 0 then
		run()
		return
	end

	pending = true
	timer = vim.defer_fn(run, DEFER_MS)

	-- Вышли раньше таймера (nvim -c q, :qa за <50 мс) — дописываем на выходе.
	vim.api.nvim_create_autocmd("VimLeavePre", {
		once = true,
		callback = function()
			if pending then
				run()
			end
		end,
	})
end

return M
