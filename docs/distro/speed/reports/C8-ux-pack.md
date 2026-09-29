# C8 — UX-пакеты: code actions, cmp, telescope, treesitter: DONE

Дата: 2026-09-29. Smoke полный: **8/8 PASS**. PTY-сессии ca–cn.

## 1. Go code action: фидбек + рабочий `go get`

Разгадка тишины: `MiniPick.setup()` глобально подменял `vim.ui.select`,
выбор уходил в mini.pick без результата наружу.
- `ga` → свой wrapper (`keymap/completion.lua::code_action_feedback`):
  запрос → выбор → apply edit / exec command через `Client:exec_cmd`
  (каноника 0.12) → нотифай applied/running/done/FAILED с причиной.
  Проверено: `Add import` → `[lsp] applied`; `Inline call` → resolve →
  честная ошибка сервера (go1.26 vs go.mod).
- Ленивый `codeAction/resolve` добавлен по ходу: gopls шлёт actions
  с одним `data`, без resolve ни edit ни command нет.
- `<leader>gg` (`keymap/go_tools.lua`): BrokenImport из диагностики →
  один confirm → `go get` по очереди с флоат-логом (справа сверху,
  `q`/Esc закрывает) → нотифай итога. Проверено на mongo-driver:
  `$ go get …` → `ok` → go.mod обновлён.
- Нюанс: наш `didChangeWatchedFiles` выключен, gopls не видит новый go.mod —
  после `gg` нужен `<leader>lr` (написано во флоате).

## 2. cmp: каждый символ + прогрев

- `keyword_length 2→1`: меню с ПЕРВОЙ буквы (проверено: `f` → `fmt [LSP]`).
  Спам гасится точечно: buffer от 3 символов, docstring из кэша (C2).
- `performance`: debounce 60→30, throttle 30→20, fetching_timeout 500→300.
- Прогрев: luasnip догружается в schedule вместе с cmp (было только cmp).
- После брожения по внешней либе cmp жив (меню `Fscan/Print…`).

## 3. Диагностика: virtual_lines выключены по умолчанию

`settings.diagnostics_virtual_lines = true→false`. Остаются signs +
текст в конце строки, прыжки `g[/g]`, тоггл `<leader>lv`. Проверено live.

## 4. gd без квикфикса

- Было: фолбэк внешних либ всегда открывал quickfix.
- Стало: ровно одно объявление (или ровно одно НЕметод-объявление, или
  уникальный минимум глубины пути — `mongo/type Client` против
  `options/func Client` и `Database.Client`) → прямой прыжок + `m'`.
  Проверено: `gd` на `Client` → сразу `mongo/client.go: type Client struct`.
- Квалификатор `mongo` на позиции курсора → прыжок на строку импорта
  (прямо, без квикфикса). `gd` на `Errorf` → `GOROOT/fmt/errors.go:23`.

## 5. Telescope вместо mini.pick

- `:DistroInstall telescope.nvim --yes` (lock записан), бэкенд `pick.lua`
  переписан таблицей имён (хоткеи в `tool.lua` НЕ менялись — те же lhs).
  Проверены: ff (превью), gr (400 референсов с превью + честное «нет ссылок»),
  gO, fb, fw, fo (376), commands (149), visual fs→grep_string.
- mini.nvim удалён (manifest/lock/pack/config), `:Distro` 21/0/0.
  Бонус: пропал глобальный hijack `vim.ui.select` — `ga` теперь на builtin.
- Мёртвая настройка `search_backend` (write-only) удалена; health/benchui/
  комменты переведены на telescope.

## 6. Treesitter: был сломан, починен (две находки)

- **Лоадер никогда не грузил treesitter**: `plugin/*.vim` textobjects требует
  модули родителя, а пакуется раньше него → packadd падал → всё поддерево
  мертво (ни highlight, ни textobjects — `:Inspect` показывал vim-syntax).
  Фикс: rtp-only фолбэк `packadd!` в `pack_subtree` (без UI молча, чтобы не
  ломать smoke-парсинг — проверено) + явный `init()` textobjects в конфиге
  + сброс отравленного `package.loaded` (первая неудача залипала в sentinel
  «loop or previous error» навсегда).
- Проверено: `keyword.function` на `func`, `xmap af` существует,
  `:DistroParsers` 21 парсер, `:TreesitterTier` работает.

## 7. E2E mongo-проект (/tmp/qa-ca)

`go mod init` → импорт mongo → `ga` (notify) → `gg` (float, ok) →
`<leader>lr` → gopls резолвит (остался честный vet про копирование lock) →
`gd` в `mongo/client.go` → `gr/gO/K` → cmp после либы жив →
процессы: 2 gopls (2 корня: проект + module cache — by design, не спам).

## Замеры

- smoke 8/8; старт empty 76-78, go 163-187, big 148-160 (разброс прогонов
  ±10мс, эффект изменений в пределах шума — стартовую цену не трогали);
- `lua/`: 15119 → **15454 (+335: go_tools, ga-wrapper, tele-бэкенд)**;
- вендор: −mini +telescope.

## Остаток/риски

- InlayHint-спам `no package metadata` на битых файлах (серверный, бэклог).
- `tui-test type` шлёт paste (lp-гейт cmp скипает) — стенд: клавиши по одной.
