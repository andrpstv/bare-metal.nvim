-- https://github.com/neovim/nvim-lspconfig/blob/master/lua/lspconfig/configs/gopls.lua
local settings = require("core.settings")

-- PERF_LEAN (C, ось gopls): снимает самый дорогой компонент — фоновые анализы
-- gopls. ВАЖНО, где читается флаг: здесь, при ПЕРВОЙ загрузке этого модуля,
-- то есть на первом Go-буфере (lsp.lua регистрирует сервер на BufReadPre), а
-- не на старте сессии. Поэтому :PerfLeanOn/переключение флага в середине сессии
-- не врёт, но и не мгновенно: новый клиент gopls подхватывает новое значение,
-- уже поднятый сервер — нет (то же поведение, что у perf_defer: «applies to
-- FUTURE loads»). Специально НЕ читаем флаг на этапе core.settings, иначе
-- значение запекалось бы до того, как владелец успел его переключить.
local weak = (function()
	local ok, perf = pcall(require, "core.perf")
	if ok and perf and perf.lean_axis then
		return perf.lean_axis("gopls")
	end
	return settings.gopls_weak_hw == true
end)()

-- Codelenses. Ловушка, на которую владелец наступит: в старом коде было
-- `cl.X ~= false`, где cl = settings.gopls_codelenses or {}. При пустой таблице
-- `nil ~= false` истинно для ВСЕХ восьми ключей, то есть «ничего не настроил»
-- означало «включить всё» — ровно наоборот интуиции. Теперь:
--   * ключ не задан (nil)  -> штатное поведение (всё включено);
--   * таблица пустая ({})  -> все codelenses выключены, перечислять не нужно;
--   * ключ = false         -> этот выключен, остальные по умолчанию включены.
local cl = settings.gopls_codelenses
local function lens_on(name)
	-- Пресет «слабое железо» выключает все codelenses независимо от таблицы:
	-- codelenses — самая частая фоновая активность gopls на больших графах.
	if weak then
		return false
	end
	if cl == nil then
		return true
	end
	if next(cl) == nil then
		return false
	end
	return cl[name] ~= false
end

-- GOMODCACHE / GOROOT reuse (incident: gd внутри mongo-driver
-- bson/reader.go падал с "no package metadata for file ...").
-- vim.fs.root() на dependency-файле находит СОБСТВЕННЫЙ go.mod модуля
-- внутри $GOMODCACHE (каждый распакованный модуль несёт свой go.mod, а
-- mongo-driver v2 — ещё и go.work с ./examples, ./ext/awsauth и др.,
-- которых нет в zip: `go list` там падает с 7 missing-модулями).
-- Итог: второй gopls с корнем в read-only кэше, оторванный от consumer
-- workspace, который этот модуль импортирует, — отсюда no package metadata
-- на definition/hover/references. Фикс повторяет upstream lspconfig
-- (nvim-lspconfig#804, lsp/gopls.lua): файл из lib — аттачим к существующему
-- gopls-workspace, а не стартуем кэш-корневой сервер.
-- Sync fast path первым (is_go_lib-паттерн, без спавнов — старый `go env`
-- на каждый аттач стоил 2-4 процесса и заменён именно поэтому); кэшированные
-- `go env`-пути покрывают кастомные GOPATH/GOMODCACHE, которые паттерн не ловит.
local mod_cache_dir, goroot_src_dir, go_dirs_queried = nil, nil, false
local function query_go_dirs()
	if go_dirs_queried then
		return
	end
	go_dirs_queried = true
	-- Синхронный fast path без спавна: пользовательский экспорт сразу в дело,
	-- асинхронный `go env` ниже только уточнит дефолты.
	if vim.env.GOMODCACHE and vim.env.GOMODCACHE ~= "" then
		mod_cache_dir = vim.env.GOMODCACHE
	end
	if vim.env.GOROOT and vim.env.GOROOT ~= "" then
		goroot_src_dir = vim.env.GOROOT .. "/src"
	end
	if vim.fn.executable("go") ~= 1 then
		return
	end
	vim.system({ "go", "env", "GOMODCACHE", "GOROOT" }, { text = true }, function(obj)
		vim.schedule(function()
			if not obj or obj.code ~= 0 then
				return
			end
			local lines = vim.split(vim.trim(obj.stdout or ""), "\n")
			if lines[1] and lines[1] ~= "" then
				mod_cache_dir = lines[1]
			end
			if lines[2] and lines[2] ~= "" then
				goroot_src_dir = lines[2] .. "/src"
			end
		end)
	end)
end

local is_windows_lib = vim.uv.os_uname().sysname == "Windows_NT"
local function norm_lib(p)
	p = (p or ""):gsub("\\", "/")
	if is_windows_lib then
		p = p:lower()
	end
	return p
end
-- realpath один раз на путь (lstat, без спавнов): GOMODCACHE/GOROOT из `go env`
-- бывают нерезолвленными (/tmp/custom на macOS), а bufname Neovim уже
-- резолвит (/private/tmp/custom) — голое prefix-сравнение тогда мимо.
-- Неудача realpath (нет файла) — откат к сырой строке, не ошибка.
local real_cache = {}
local function real_lib(p)
	if not p or p == "" then
		return p
	end
	local hit = real_cache[p]
	if hit ~= nil then
		return hit
	end
	local ok, rp = pcall(vim.uv.fs_realpath, p)
	if not ok or not rp or rp == "" then
		rp = p
	end
	-- Bounded: долгие сессии с тысячами файлов не должны растить таблицу вечно.
	if real_cache._n and real_cache._n > 512 then
		real_cache = { _n = 0 }
	end
	real_cache[p] = rp
	real_cache._n = (real_cache._n or 0) + 1
	return rp
end
local function under_lib(dir, fname)
	if not dir or dir == "" or not fname or fname == "" then
		return false
	end
	dir = norm_lib(real_lib(dir)):gsub("/+$", "")
	fname = norm_lib(real_lib(fname))
	return fname:sub(1, #dir) == dir and (fname:sub(#dir + 1, #dir + 1) == "/" or #fname == #dir)
end

local function lib_root_of(client)
	local r = client and client.config and client.config.root_dir
	if type(r) ~= "string" or r == "" then
		return nil
	end
	return r
end

local function cache_rooted(r, utils_ok, utils)
	if utils_ok and utils.is_go_lib and utils.is_go_lib(r) then
		return true
	end
	if under_lib(mod_cache_dir, r) or under_lib(goroot_src_dir, r) then
		return true
	end
	return false
end

-- Корень gopls-клиента, обслуживающего буфер (только настоящий workspace,
-- не кэш-корневой). nil = такого нет.
local function workspace_root_for(buf, utils_ok, utils)
	for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "gopls" })) do
		local r = lib_root_of(c)
		if r and not cache_rooted(r, utils_ok, utils) then
			return r
		end
	end
	return nil
end

return {
	root_dir = function(bufnr, on_dir)
		local f = vim.api.nvim_buf_get_name(bufnr)
		query_go_dirs()
		local ok_u, utils = pcall(require, "modules.utils")
		local pattern_hit = ok_u and utils.is_go_lib and utils.is_go_lib(f)
		if pattern_hit or under_lib(mod_cache_dir, f) or under_lib(goroot_src_dir, f) then
			-- 1) Контекст перехода: workspace буфера, откуда пришли (alternate).
			-- Покрывает A→depA при живых клиентах A и B: depA наследует A,
			-- а не первого/свежайшего клиента. В цепочке dep→dep alternate —
			-- сам dep, уже сидящий на правильном workspace.
			local alt = vim.fn.bufnr("#")
			if alt and alt > 0 and alt ~= bufnr and vim.api.nvim_buf_is_valid(alt) then
				local r = workspace_root_for(alt, ok_u, utils)
				if r then
					on_dir(r)
					return
				end
			end
			-- 2) Recency fallback: свежайший подходящий клиент (parity с
			-- upstream: последний открытый проект ближе к текущему контексту).
			-- Кэш-корневых пропускаем: их корень и есть сломанный
			-- (standalone `nvim $GOMODCACHE/...` без workspace).
			local cands = vim.lsp.get_clients({ name = "gopls" })
			for i = #cands, 1, -1 do
				local r = lib_root_of(cands[i])
				if r and not cache_rooted(r, ok_u, utils) then
					on_dir(r)
					return
				end
			end
			-- Workspace пока нет (standalone-открытие dependency):
			-- падаем в маркерный поиск ниже, чтобы LSP всё равно встал.
		end
		on_dir(vim.fs.root(f, { "go.work", "go.mod", ".git" }) or vim.fn.getcwd())
	end,
	cmd = { "gopls" },
	filetypes = { "go", "gomod", "gowork", "gosum", "gotmpl", "gohtmltmpl", "gotexttmpl" },
	flags = {
		allow_incremental_sync = true,
		-- Слабое железо: debounce выше = реже пересчёт фоновых анализов.
		debounce_text_changes = weak and (settings.gopls_weak_hw_debounce or 250) or (settings.gopls_debounce or 150),
	},
	capabilities = {
		-- gopls шлёт client/registerCapability для didChangeWatchedFiles порой
		-- на несуществующие пути (неразрешённые модули без go.sum): nvim тогда
		-- падает в watch.watch ENOENT-нотифай. Отказываемся штатным путём —
		-- рантайм сам игнорирует такие регистрации (см. _watchfiles.lua:50).
		-- Цена: gopls не узнает о внешних изменениях файлов (git checkout,
		-- go generate) до взаимодействия с буфером; открытые файлы шлют
		-- didOpen/didChange/didSave как обычно.
		workspace = { didChangeWatchedFiles = { dynamicRegistration = false } },
		textDocument = {
			completion = {
				contextSupport = true,
				dynamicRegistration = true,
				completionItem = {
					commitCharactersSupport = true,
					deprecatedSupport = true,
					preselectSupport = true,
					insertReplaceSupport = true,
					labelDetailsSupport = true,
					snippetSupport = true,
					documentationFormat = { "markdown", "plaintext" },
					resolveSupport = {
						properties = {
							"documentation",
							"details",
							"additionalTextEdits",
						},
					},
				},
			},
		},
	},
	settings = {
		gopls = {
			gofumpt = true,
			-- PERF: staticcheck на больших файлах заметно утяжеляет диагностику gopls.
			staticcheck = false,
			semanticTokens = (not weak) and settings.gopls_semantic_tokens ~= false,
			usePlaceholders = true,
			completeUnimported = (not weak) and settings.gopls_complete_unimported ~= false,
			symbolMatcher = "Fuzzy",
			buildFlags = { "-tags", "integration" },
			semanticTokenTypes = { string = false },
			directoryFilters = { "-.git", "-.vscode", "-.idea", "-node_modules" },
			analyses = {
				nilness = true,
				unusedparams = true,
				unusedwrite = true,
				useany = true,
				-- Дорогой memory-анализ: выключается через settings.gopls_fieldalignment
				-- либо целиком осью perf_lean.gopls.
				fieldalignment = (not weak) and settings.gopls_fieldalignment ~= false,
				httpresponse = true, -- незакрытые http response body
			},
			codelenses = {
				generate = lens_on("generate"),
				gc_details = lens_on("gc_details"),
				test = lens_on("test"),
				tidy = lens_on("tidy"),
				vendor = lens_on("vendor"),
				regenerate_cgo = lens_on("regenerate_cgo"),
				upgrade_dependency = lens_on("upgrade_dependency"),
				organizeImports = lens_on("organizeImports"),
			},
		},
	},
}
