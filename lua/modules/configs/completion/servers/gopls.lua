-- https://github.com/neovim/nvim-lspconfig/blob/master/lua/lspconfig/configs/gopls.lua
local settings = require("core.settings")

-- PERF_LEAN (C, ось gopls): снимает самый дорогой компонент — фоновые анализы
-- gopls. ВАЖНО, где читается флаг: здесь, при ПЕРВОЙ загрузке этого модуля,
-- то есть на первом Go-буфере (lsp.lua регистрирует сервер на BufReadPre), а
-- не на старте сессии. Поэтому :WeakHwOn/переключение флага в середине сессии
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

return {
	-- PERF: штатный root_dir lspconfig дергает `go env` 2-4 раза на каждый аттач;
	-- заменяем чистым поиском маркеров без внешних процессов.
	root_dir = function(bufnr, on_dir)
		local f = vim.api.nvim_buf_get_name(bufnr)
		on_dir(vim.fs.root(f, { "go.work", "go.mod", ".git" }) or vim.fn.getcwd())
	end,
	cmd = { "gopls" },
	filetypes = { "go", "gomod", "gosum", "gotmpl", "gohtmltmpl", "gotexttmpl" },
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
