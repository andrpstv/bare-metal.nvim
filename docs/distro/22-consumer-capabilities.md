# 22 — Возможности дистрибутива для потребителя (аудит capabilities)

Дата: 2026-09-27. Neovim 0.11.4. Хост измерений: **macOS 26.3 (arm64), SSD, APFS** —
это НЕ целевая платформа потребителя (Windows/HDD/слабый CPU). Всё, что не измерено
живым прогоном на целевой платформе, помечено **НЕ ИЗМЕРЕНО**.

**Роль:** аудит. Конфиг не менялся, коммитов не делалось, кода не писалось.
Все живые проверки — read-only прогоны `nvim --headless` и чтение исходников.

**Прочитано, не повторяется:** 19, 20, 21 (диагностика/трейс), 12–18 (латентность/аудит).

---

## Итог одной строкой

Дистрибутив функционально богат и внутренне честен (25 команд, 187 хоткеев, 26 вендоренных
плагинов, zero-auto-network), но **не готов к выдаче потребителю «из коробки»**: у него нет
ни одного файла, который объяснял бы обычному человеку, что делать, и на голом клоне
не работает подсветка синтаксиса. Это блокеры документации и онбординга, а не кода.

---

## 1. ПОЛНЫЙ ИНВЕНТАРЬ КОМАНД (ФАКТ)

Всего `nvim_create_user_command` в конфиге: **23 статических + 2 динамических механизма**.
Каждая строка проверена на существование реализации.

### 1.1 Загрузка / установка (дистрибутив-менеджер)

| Команда | Что делает | Реализация |
|---|---|---|
| `:Distro` | флоат-меню плагинов; **ничего не качает** при открытии | `lua/distro/init.lua:7` → `distro/ui.lua:open()` |
| `:DistroInstall [name]` | curl-установка одного плагина, confirm-gated | `lua/distro/init.lua:11` → `distro/install.lua:install_one` |
| `:DistroUpdate` | синк устаревших к пину манифеста | `lua/distro/init.lua:63` → `distro/ui.lua:407 do_sync_outdated` |
| `:DistroClean` | удаление неиспользуемого | `lua/distro/init.lua:67` → `distro/ui.lua:do_clean` |
| `:DistroCheck` | локальная проверка, **без сети** | `lua/distro/init.lua:71` → `distro/lock.lua:status()` |
| `:DistroParsers [lang\|--all]` | установка treesitter-парсеров | `lua/distro/init.lua:113` → `distro/treesitter.lua:219 install_all` |
| `:DistroTools [--install X]` | проверка/установка системных бинарников | `lua/distro/init.lua:82` → `distro/tools.lua:20 check_all` |
| `:DistroBinaries` | меню LSP/линтеров/форматтеров | `lua/distro/init.lua:198` → `distro/tools.lua:294 open_binaries` |
| `:DistroMirror <sub>` | корпоративное зеркало (status/on/off/set-url/test) | `lua/distro/init.lua:202` → `distro/mirror_cmd.lua` |

### 1.2 Диагностика

| Команда | Что делает | Реализация |
|---|---|---|
| `:ConfigHealth` | `checkhealth core`: бинарники, LSP, тема, хоткеи, плагины, старт | `lua/core/init.lua:214` → `lua/core/health.lua` |
| `:DistroDiag` | потребительский отчёт: LspAttach, фазы, пути, gopls RTT | `lua/distro/diag.lua:864` (дубль объявления — см. §1.5) |
| `:DistroTrace <sub>` | трейс действий: on/off/toggle/flush/report/open/sort/clear | `lua/distro/init.lua:143` |
| `:DistroBench` | бенчмарк машины (open times, gd/gr RTT) | `lua/distro/init.lua:135` |
| `:DistroBenchUI` | бенчмарк живого UI-рендера | `lua/distro/init.lua:139` |

### 1.3 Настройка поведения

| Команда | Что делает | Реализация |
|---|---|---|
| `:TurboOn/Off/Status` | отложенный режим загрузки (env `NVIM_TURBO=1`) | `lua/core/turbo.lua:53,56,59` |
| `:WeakHwOn/Off/Status` | пресет слабого железа (env `NVIM_WEAK_HW=1`) | `lua/core/weak_hw.lua:141,144,147` |
| `:PairsStatus` | статус автопар по filetype | `lua/core/pairs.lua:177` |

### 1.4 Форматирование / treesitter

| Команда | Что делает | Реализация |
|---|---|---|
| `:Format` | отформатировать буфер | `lua/modules/configs/completion/formatting.lua:12` |
| `:FormatToggle` | вкл/выкл format-on-save | `.../formatting.lua:19` |
| `:FormatterToggleFt <ft>` | блок-лист форматтера на filetypes | `.../formatting.lua:24` |
| `:TreesitterTier` | цикл full→lite→off для буфера | `lua/modules/configs/editor/treesitter.lua:94` |

### 1.5 Динамические команды (ФАКТ, найдено при grep)

- **Lazy-заглушки для catalog-плагинов** — `lua/distro/loader.lua:429` `boot_cmd_stub()`.
  Проверено: `:Oil` в чистом headless **не падает**, а печатает
  `[Distro] 'oil.nvim' is missing. Open :Distro and press I to install. Nothing was downloaded.`
  Т.е. заглушки для `Oil/Open/Telescope/NvimTreeToggle/Neogit/ToggleTerm/Tutor/TOhtml/Trouble/Inspect*`
  **существуют и ведут себя честно**. НЕ ИЗМЕРЕНО: то же самое на Windows.
- **Обёртка traced-команд** — `lua/distro/tracehooks.lua:155` пересоздаёт команды при
  включённом трейсе. Не новая команда, а перерегистрация.
- **Дублирование**: `:DistroDiag` объявлен дважды — `lua/distro/init.lua:129` и
  `lua/distro/diag.lua:864`. Второе перекрывает первое; ошибки нет, `:ConfigHealth` подтвердил
  работоспособность. Косметический дефект, НЕ блокер.

### 1.6 Сверка со `scripts/smoke-test.sh` (ФАКТ, важно)

Список `COMMANDS` в `scripts/smoke-test.sh:196` содержит **25 имён** (в постановке задачи
указано 24 — фактически 25). Живой прогон `./scripts/smoke-test.sh --quick` → **7 passed,
0 failed, 1 skipped** (skipped = startup-бенчмарк, требует `--quick` снять).

**НАХОДКА — проверка check 4 неполноценна.** Логика на `scripts/smoke-test.sh:215-219`:
команда, не найденная в рантайме, но объявленная в `lua/modules/`, классифицируется как
`LAZY_OK` и **засчитывается как PASS**. Проверено изолированно:

```
EXISTS_OUT=[MISSING TreesitterTier]
  -> TreesitterTier classified LAZY_OK (counted as PASS)
```

`:TreesitterTier` действительно отсутствует в рантайме при `nvim --headless -c 'qa!'`
(команда регистрируется только при загрузке treesitter-конфига). То есть **4 из 25 команд
(`Format`, `FormatToggle`, `FormatterToggleFt`, `TreesitterTier`) физически не могут
уронить эту проверку**. ВЫВОД: smoke-тест не является гарантией существования этих
команд — только статической гарантией, что строка `nvim_create_user_command` есть в исходнике.

### 1.7 Мёртвых команд не найдено (ФАКТ)

Все 23 статические команды привязаны к существующим функциям; «объявлено, но не вызывается»
не найдено. Заполнители (`_pick*`, `_toggle_*`) определены в `lua/keymap/helpers.lua`
и `lua/keymap/pick.lua`.

---

## 2. ЧТО ПОТРЕБИТЕЛЬ ПОЛУЧАЕТ ИЗ КОРОБКИ

### 2.1 Практический гид (составлен по коду, НЕ из документации)

| Хочу | Как |
|---|---|
| Открыть файл, получить подсветку | открыть файл (нужен установленный парсер, см. §2.4) |
| Найти файл в проекте | `<leader>ff` (`lua/keymap/tool.lua:78`) |
| Живой поиск по проекту | `<leader>fp` (`tool.lua:73`) |
| Перейти к определению | `gd` в буфере с LSP (`lua/keymap/completion.lua:100`) |
| Найтиreferences | `gr` (`completion.lua:88`) |
| Переименовать | `<leader>rn` (`completion.lua:102`) |
| Документация по символу | `K` (`completion.lua:95`) |
| Список ошибок | `gt` / `<leader>ld` (`lua/keymap/tool.lua:47,52`) |
| Отформатировать | `<leader>fm` (`lua/keymap/completion.lua:4`) |
| Git: hunks, stage, blame | `]g` `[g` `<leader>gs` `<leader>gb` (`lua/keymap/ui.lua:46-86`) |
| Проводник | `<leader>e` — встроенный netrw (`lua/keymap/tool.lua:10`) |
| Проверить машину | `:ConfigHealth`, `:DistroDiag` |
| Поставить плагин | `:Distro` → `I` |

### 2.2 Документация для потребителя ОТСУТСТВУЕТ (ФАКТ, блокер)

- `README.md` — это **апстримный README nvimdots** (заголовок `nvimdots`, ссылки на
  `ayamir/nvimdots`, Discord, DeepWiki, ветки 0.9/0.10/0.12). Ни одной строки про
  `distroManager`, `:Distro*`, `gopls`, keymap-раскладку. Для потребителя это документ
  чужого проекта.
- `docs/distro/00-requirements.md` — контракт для разработчика: «Source: discussion
  2026-09-24. This file is the contract. Any behavior change must update it first»,
  §2 «Zero-auto-network (hard rule)», §3 «Download method: curl-only».
- `docs/distro/01-architecture.md` — «Module contracts», диаграмма `pack/`, описания полей.
- `docs/distro/03-implementation-steps.md` — «Execution order. Each step ends with a
  verification. Stop on red», чекбоксы `- [ ]`.

**ВЫВОД:** ни один из проверенных файлов (README, 00, 01, 03) не написан для обычного
человека. Нет: оглавления возможностей, таблицы хоткеев, инструкции «как поставить gopls»,
раздела «что делать, если тормозит», списка внешних зависимостей. **Не найдено:** файла
типа QUICKSTART/INSTALL для потребителя во всём репозитории.

---

## 3. ХОТКЕИ

### 3.1 Счёт (ФАКТ, измерено в рантайме)

| Режим | Количество |
|---|---|
| normal | 114 |
| insert | 32 |
| visual | 16 |
| select (x) | 13 |
| command-line | 7 |
| terminal | 4 |
| operator-pending | 1 |
| **Итого** | **187** |

Исходники: 138 вызовов `map(` в `lua/keymap/*.lua`. Плюс буферные LSP-мапы
(`lua/keymap/completion.lua` `M.lsp`) и gitsigns-мапы (`lua/keymap/ui.lua:46` `M.gitsigns`),
которые навешиваются per-buffer.

### 3.2 Группы

- **Пакетный менеджер** (`lua/keymap/init.lua:12-21`, 10 шт.): `ph ps pu pi pl pc pd pp pr px`.
  Замечания: `pc`/`pp`/`pr` — **дубли** `ps`/`pl`/`pu` (одинаковые RHS). Мёртвые, но не вредные.
- **LSP** (`completion.lua:66-140`): `gd gr gR gi gI gy gw gO g[ g] K ga gs K` + `<leader>li/lr/lx/lv/lh/cl/rn`.
- **Навигация/поиск** (`tool.lua:73-118`): `<C-p>`, `<leader>fp/ff/fb/f/ /fo/fh/fg/fw/fr`, visual `<leader>fs`.
- **Буферы/окна/табы** (`ui.lua:4-40`): `<leader>bn/q/sv/sh/sc`, `[b ]b [q ]q`, `<A-q>`,
  `<C-h/j/k/l>`, `tn tk tj to`, terminal `<C-w>h/j/k/l`.
- **Git** (`ui.lua:46-86` буферные + `editor.lua:98-106`): `]g [g <leader>gs/gr/gR/gp/gb`,
  `<leader>gd/gD/gh`, `ih` text-object.
- **Форматирование** (`completion.lua:4,7`): `<leader>fm`, `<leader>ft`.
- **Go** (`lang.lua:6-30`, 9 шт.): `<leader>gt/ta/gf/ga/gx/gm/fs/ie/ar`.
- **Терминал/прочее** (`tool.lua:47`): `gt` (trouble), `&` (формат).
- **Редактирование** (`editor.lua`, 49 шт.): `jj/jk`, `<C-s>`, `<C-q>`, `Y D J`, `n/N` с центрированием,
  `J`, `<S-Tab>`, `<Esc>`, `<leader>o` (spell), `<leader>x` (chmod), `<leader>S`, `<leader>ss/sl` (сессии).

### 3.3 Конфликты со встроенными (ФАКТ)

- `grn/grr/gri/gra/grt` из `vim/_defaults.lua` **успешно удаляются** на `VimEnter`
  (`lua/keymap/init.lua:40-47`). Проверено: до `VimEnter` — `mapcheck()` истинно для всех пяти,
  после `doautocmd VimEnter` — все пять пусты. Это осознанное и корректное решение
  (иначе голый `gr` ждал бы `timeoutlen`).
- Переопределены встроенные: `K` (LSP hover, буферно), `gd`/`gr` (LSP, буферно),
  `gO`, `g[`, `g]`, `gs`, `n`, `N`, `Y`, `D`, `J`, `<C-d>`, `<C-u>`, `<Esc>`, `gt`.
  Для потребителя это **не проблема**, но требует упоминания: `gd`/`gr`/`K` — НЕ
  «go-to-define», пока не приаттачился LSP (в Go-буфере переопределены на LSP-варианты).
- Конфликта `<C-w>` не возникает: window-мапы используют встроенные `<C-w>*` как RHS.

### 3.4 Работают ли (ФАКТ, живая проверка)

- **Go-команды** `:GoTestFunc :GoTest :GoAlt :GoFillStruct :GoIfErr` — `exists()==0` в пустом
  headless-буфере, `exists()==2` в Go-буфере с `go.mod` (gopls поднялся, `lsp_clients=1`).
  **ВЫВОД:** работают, но строго filetype-gated. Потребитель без Go-файла их не увидит.
- **LSP-команды** `:LspInfo :LspRestart` — `0` в пустом буфере, `2` в Go-буфере
  (регистрируются в `M.lsp`). Работают.
- **Заглушки не врут**: `:DiffviewOpen :DiffviewClose :DiffviewFileHistory :Trouble :Neogit` → `2`
  (diffview/trouble реально установлены; `:Neogit` — заглушка catalog).
- Плагин-зависимые функции (`_pick*` в `pick.lua`, `_toggle_*` в `helpers.lua`) —
  заглушки не «носят», а `pcall`-ят `require("distro.loader").load(...)` и при неудаче
  честно notify (`pick.lua:48`).

---

## 4. ПЛАГИНЫ

### 4.1 Вендоренные: 26 (2 eager + 24 opt) — `lua/distro/manifest.lua:9-73`

| # | Плагин | kind | Триггер | Зачем потребителю |
|---|---|---|---|---|
| 1 | black-metal-theme-neovim | **start** | всегда | тема `khold` |
| 2 | nvim-web-devicons | **start** | всегда | иконки в statusline/дереве |
| 3 | gitsigns.nvim | opt | BufReadPost, idle | знаки изменений, stage/blame/hunks |
| 4 | nvim-lspconfig | opt | BufReadPre/BufNewFile | LSP |
| 5 | nvim-cmp | opt | InsertEnter/CmdlineEnter + schedule | автодополнение |
| 6 | LuaSnip | opt | вместе с cmp | сниппеты (`build = make install_jsregexp`) |
| 7 | friendly-snippets | opt | вместе с cmp | набор сниппетов |
| 8-12 | cmp_luasnip, cmp-nvim-lsp, cmp-path, cmp-buffer, cmp-cmdline | opt | вместе с cmp | источники дополнения |
| 13 | nvim-treesitter | opt | BufReadPre, build | подсветка/парсинг |
| 14 | nvim-treesitter-textobjects | opt | вместе с treesitter | текст-объекты |
| 15 | flash.nvim | opt | CursorHold(I) | переходы `f`/`t`/textobj |
| 16 | diffview.nvim | opt | по команде | диффы/история |
| 17 | plenary.nvim | opt | по требованию | curl для diffview |
| 18 | mini.nvim | opt | по требованию (`_pick_ensure`) | пикеры: файлы/grep/буферы/help |
| 19 | trouble.nvim | opt | по команде | список диагностик |
| 20 | go.nvim | opt | ft=go/gomod/gosum | тесты, теги структур, tidy |
| 21 | guihua.lua | opt | вместе с go.nvim | UI go.nvim |
| 22 | nvim-lint | opt | `:Lint` (не на открытии!) | golangci-lint |
| 23-26 | nvim-dap, nvim-dap-go, nvim-dap-ui, nvim-nio | opt | `:DapContinue` и др. | отладка Go через dlv |

Факт: `ls pack/distro/opt` = 24, `ls pack/distro/start` = 2. Все 26 на месте, health
подтверждает «26 plugins installed, no errors».

### 4.2 Catalog (9, НЕ установлены) — `manifest.lua:100-108`

`telescope.nvim, oil.nvim, toggleterm.nvim, which-key.nvim, todo-comments.nvim,
lualine.nvim, indent-blankline.nvim, neogit, nvim-tree.lua`.
Проверено: ни одного каталога в `pack/` — **0 из 9 установлено**.

**НАХОДКА (важно для потребителя):** `which-key.nvim` — catalog, то есть
**всплывающая подсказка по хоткеям у потребителя не работает**. Человек с 187 хоткеями
и без `:help` и без which-key не имеет способа их discover. Это один из самых болезненных
пробелов именно для «слабый ПК / первый раз».

**НАХОДКА (безопасность/гигиена):** в `~/.local/share/nvim/site/lazy` лежит **106
каталогов** от старого lazy.nvim (`manifest.lua:8` его исключает, `distro/ui.lua:488`
называет их «old manager leftover»). Для потребителя, мигрирующего с nvimdots+ lazy,
это 106 мёртвых директорий. НЕ ИЗМЕРЕНО: сколько из них реально подхватывается —
в моём rtp `site/lazy` не присутствует, команды приходили из заглушек `boot_cmd_stub`.

### 4.3 Для слабого ПК (ВЫВОД)

- Хорошо: eager ровно 2 плагина; `nvim-dap` (~60 модулей) и `nvim-lint` убраны с
  filetype-триггеров на требование (комментарии `manifest.lua:55-57,59-61`).
- Тяжёлое, но обоснованное: treesitter (нужен для подсветки) и nvim-cmp.
- Лишнего для потребителя не найдено: каждый из 26 закрывает реальную функцию,
  дублирующих плагинов (два пикера, два статулайна) нет — mini.pick + свой statusline
  в `keymap/statusline.lua` вместо lualine.

---

## 5. ЯЗЫКИ И ИНСТРУМЕНТЫ

### 5.1 Поддерживаемые языки (ФАКТ)

LSP: `lsp_deps = { bashls, lua_ls, gopls }` — `lua/core/settings.lua:174-178`.
Т.е. **Lua, Go, Bash/shell** — и всё. Конфиги: `lua/modules/configs/completion/servers/`
(`gopls.lua, lua_ls.lua, bashls.lua, clangd.lua, dartls.lua, html.lua, jsonls.lua, pylsp.lua`).
**ВЫВОД:** конфиги для Python/C/C++/JSON/HTML/Dart лежат в репозитории, но НЕ включены
в `lsp_deps` — потребитель Python/C должен сам дописать имя в `settings.lua`. Никакой
команды «включить поддержку Python» не существует — **не найдено**.

Линтер: **только Go** — `lint.linters_by_ft = { go = { "golangcilint" } }`
(`lua/modules/configs/lang/lint.lua:7`). Срабатывает по BufWritePost.

Форматтеры: `format_on_save = true` (`settings.lua:11`), но серверы форматирования
в `server_formatting_block_list` — `clangd, lua_ls, ts_ls, null-ls` (`settings.lua:41-46`),
т.е. форматирование идёт через LSP. Отдельные бинарники-форматтеры (stylua, shfmt)
есть в `manifest.binaries` (`manifest.lua:128,135`), но **не подключены к автоформату**.

### 5.2 Что нужно поставить руками (ФАКТ, `manifest.lua:116-151`)

| Бинарник | method | Что делает установщик | Кто ставит |
|---|---|---|---|
| `gopls` | go | `go install golang.org/x/tools/gopls@latest` | **вручную** (нужен Go + GOPROXY) |
| `dlv` | go | `go install github.com/go-delve/delve/cmd/dlv@latest` | вручную |
| `staticcheck` | go | `go install honnef.co/go/tools/...` | вручную |
| `lua-language-server` | release | curl-архив с GitHub → `tools/` | `:DistroBinaries` |
| `stylua` | release | curl zip → `tools/` | `:DistroBinaries` |
| `shfmt` | release | curl бинарь → `tools/` | `:DistroBinaries` |
| `golangci-lint` | release | curl tar.gz → `tools/` | `:DistroBinaries` |
| `bash-language-server` | system | **только hint** (npm) | вручную |
| `marksman` | system | **только hint** | вручную |

Системные требования: `curl` (required), `tar` (required), `rg`, `gcc|cc|clang`, `make`, `go`
— `manifest.lua:78-84`.

### 5.3 Есть ли одна команда «поставь всё»? (ФАКТ)

**Нет.** `:DistroTools --install <tool>` ставит **один** инструмент (`init.lua:82-95`).
`:DistroBinaries` — меню, где номер строки ставит **один** бинарник
(`tools.lua:333-355`). Единственная «пакетная» команда во всём конфиге —
`:DistroParsers --all` (`init.lua:120-122`), и только для парсеров.

**ВЫВОД (блокер для потребителя):** чтобы получить рабочий Go-стек, потребитель обязан
вручную: поставить Go → `go install gopls` → отдельно `golangci-lint` через
`:DistroBinaries` → отдельно `:DistroParsers --all` (каждый парсер компилируется
`cc`, 20 языков). Ни одной команды, которая делает это целиком, **не найдено**.

---

## 6. ЧТО СЛОМАНО ИЛИ ОПАСНО

### 6.1 Живые прогоны (ФАКТ)

| Проверка | Результат |
|---|---|
| `smoke-test.sh --quick` | 7 passed, 0 failed, 1 skipped |
| `nvim --headless -c 'qa!'` | exit 0, stderr пуст |
| Конфиг без `rg` и `go` на PATH | exit 0, `RG=0 CC=1 GO=0`, stderr пуст |
| `:ConfigHealth` | 3 ⚠️ / 3 ❌ (см. ниже) |
| `:DistroCheck` | «0 item(s) need attention» |
| `:DistroTrace on → flush → report` | 29 строк, сортировка по времени работает |
| `:DistroDiag` | отчёт записан в `~/.cache/nvim/distro-diag.txt` |
| `:WeakHwStatus` / `:TurboStatus` / `:PairsStatus` | печатают состояние корректно |

`RG=0 GO=0` при `CC=1` — конфиг **переживает отсутствие rg и Go**: `core/options.lua:156-162`
ставит `grepprg` только при наличии rg, иначе `grepformat = %f:%l:%m` под платформенный
дефолт (findstr на Windows). Это **осознанный и корректный** фолбэк.

### 6.2 Что показал `:ConfigHealth` на ЭТОМ хосте (ФАКТ)

```
- ✅ OK 26 plugins installed, no errors
- ✅ OK 5 keymaps OK
- ✅ OK LSP servers: bashls, lua_ls, gopls
- ⚠️ WARNING python3 found but pynvim missing
- ❌ ERROR 486ms (very slow)      <- порог >300ms в health.lua:396
- ✅ OK colorscheme: khold, 10 highlight groups OK
```

**ВЫВОД:** 486ms на macOS/SSD — это провал по собственному порогу конфига. На HDD
целевой потребитель получит больше. НЕ ИЗМЕРЕНО: абсолютная цифра на Windows/HDD.
Плюс: `weak_hw_profile: weak (<=2 CPUs)` — диагностика сама определила профиль слабого
железа на этом хосте, а пресет при этом **выключен** (`WEAK-HW OFF`).

### 6.3 Ложная тревога на Windows (ФАКТ — код, НЕ ИЗМЕРЕНО)

`lua/core/health.lua:49`: `local required = { "git", "curl", "unzip" }` → отсутствие
любого из трёх даёт **`vim.health.error`**.

При этом `distro/install.lua:58-64` (`check_prereqs`) требует **только `curl` и `tar`**,
и `unzip` — лишь последний fallback для zip (`install.lua:317-318`).

**ВЫВОД:** на «чистой» Windows 10/11 `unzip` не входит в поставку (`tar` входит с 10,
`curl` с 10, `unzip` — нет). Потребитель увидит **красный ERROR «missing required: unzip»**
на первом же `:ConfigHealth`, хотя установщик плагинов при этом полностью работоспособен.
Это подрывает доверие к всей диагностике. НЕ ИЗМЕРЕНО: нужно подтвердить на Windows,
но кодовая предпосылка однозначна.

### 6.4 Windows: чтение кода (НЕ ИЗМЕРЕНО — платформы нет)

Что сделано правильно:
- Шелл-квотинг под cmd.exe: `install.lua:13-20` (`Q()` — двойные кавычки, `""` для `"`).
- `null_dev()` → `NUL` на Windows (`install.lua:22-24`).
- Staging в `stdpath("cache")`, а не в репозитории — комментарий `install.lua:27-29`
  прямо называет причиной «readonly config dir (Windows: ~/AppData)».
- Клипборд: `core/init.lua:74-88` — win32yank или встроенный провайдер.
- PowerShell-режим с честным предупреждением при отсутствии (`core/init.lua:120-133`).
- `%USERPROFILE%` / `%APPDATA%` для git/lazygit (`core/git_colors.lua:46-66`).
- Диагностика печатает `%LOCALAPPDATA%` и помечает «NOT MEASURED» если переменной нет
  (`distro/diag.lua:86-95`) — образцовая честность.
- Диагностика различает `win32` / `win32unix` (WSL) / mac / linux (`diag.lua:72-79`).

Что сломается или под вопросом:
1. **`cc()` для treesitter отдаёт `cl` (MSVC)** — `distro/treesitter.lua:69`, с честным
   комментарием автора: `flags below are gcc-style, may need tuning per setup`.
   То есть на Windows без MinGW/w64devkei **сборка парсеров, скорее всего, упадёт**,
   а без парсеров нет подсветки. НЕ ИЗМЕРЕНО.
2. **Ассеты бинарников**: `golangci-lint` и `lua-language-server` качаются как `.tar.gz`
   и распаковываются `tar` (`install.lua:214-240`). bsdtar в Windows 10+ есть, но
   `install.lua:233-241` для zip-ассетов (`stylua` — zip!) полагается на `--strip-components=1`,
   с fallback `hoist_single_child` для GNU tar. Проверить нельзя — НЕ ИЗМЕРЕНО.
3. **`:DistroTools` hint для gcc на Windows** обещает `winget install ...WinLibs.POSIX.UCRT`
   или w64devkit (`tools.lua:13`), но сам установщик `install_via_curl` для gcc
   **только guidance** (`tools.lua:46-51` — для mac; ветка win не реализована).
4. **Пути к gopls**: `cmd = { "gopls" }` (`servers/gopls.lua:44`) — полагается на `$PATH`.
   `go install` на Windows кладёт бинарник в `%USERPROFILE%\go\bin`, который **не всегда**
   в PATH. Диагностика покажет «NOT MEASURED: gopls not on PATH» (`diag.lua:99-100`),
   но автоисправления/подсказки с добавлением в PATH **не найдено**.
5. Регулярки с `\\`: `lint.lua:56` — `f:match("Program Files\\Go")`. В Lua-паттерне
   `\\` = экранированный обратный слэш, корректно для Windows-путей. Не баг.
6. `keymap/editor.lua:71-76` — `<leader>x` (chmod) явно проверяет `has("win32")` и
   выдаёт понятный notify вместо E371. Корректно.
7. `health.lua:173` — `if not has("make") and not is_windows` — на Windows отсутствие
   `make` не считается проблемой. Разумно (w64devkit/TCC), но означает, что
   `LuaSnip`'s `make install_jsregexp` (`manifest.lua:34`) на Windows **не выполнится**.
   НЕ ИЗМЕРЕНО.

**Итого по Windows: 4 непроверенных места с высокой вероятностью поломки (MSVC-сборка
парсеров, zip-ассеты, gcc-установка, make/LuaSnip) и одна гарантированная ложная тревога
(unzip в health).**

---

## 7. ЧЕГО НЕТ

| Ожидается от готового дистрибутива | Статус | Доказательство |
|---|---|---|
| Справка/мастер «что это умеет» | **НЕТ** | README = апстрим nvimdots; в `lua/distro/**` нет ни `tutor`, ни `help`, ни `doctor` (grep пуст) |
| Подсказка по хоткеям (which-key) | **НЕТ из коробки** | which-key только в catalog (`manifest.lua:103`), 0 из 9 установлено |
| `:help` внутри дистрибутива | **НЕТ** | `find . -maxdepth 2 -iname "*help*"` вне `pack/` → пусто |
| Миграция существующего конфига | **НЕТ** | grep `migrat` по `lua/distro/*`, `lua/core/*` → пусто; есть только детект 106 старых каталогов `site/lazy` (`ui.lua:488`) |
| Откат/rollback версии плагина | **НЕТ** | grep `rollback` → пусто; в `distro-lock.json` есть `previous_ref` как поле, но UI-команды отката **не найдены** |
| Версия/обновление самого дистрибутива | **НЕТ** | grep `DistroVersion` → пусто. `:DistroUpdate` обновляет **плагины к пину**, не конфиг |
| «Почему тормозит» — единая команда | **частично** | `:ConfigHealth` (старт), `:DistroDiag` (LspAttach/фазы), `:DistroTrace report` (29 строк, работает — проверено) |
| Установка всех зависимостей одной командой | **НЕТ** | см. §5.3 |
| Поддержка Python/C «из коробки» | **НЕТ** | конфиги лежат, но не в `lsp_deps` (`settings.lua:174-178`) |
| Команды включения/выключения языков | **НЕТ** | только ручная правка `settings.lua` |

### 7.1 Честно о «почему тормозит» (задание просило проверить текущее состояние)

**ФАКТ:** после инцидента с трейсом диагностика **работает, а не сломана**.
Проверено живьём:
- `:DistroDiag` пишет отчёт с фазами BufReadPre/Syntax/FileType/BufReadPost/BufEnter/LspAttach,
  `_at_ms`/`_delta_ms`, `gopls_RTT1/RTT2`, путями. Файл создан, содержимое осмысленно.
- `:DistroTrace on → flush → report` вернул **29 строк**, отсортированных по времени
  (`59.13 ms loader:load/nvim-cmp`, `35.94 ms loader:finish/LuaSnip`, …).
- Трекер команд (`tracehooks.lua:155`) и агрегация CursorMoved (`tracehooks.lua:181+`)
  на месте.

**Но два реальных дефекта UX:**
1. `:DistroTrace report` сразу после `on` печатает `No trace log yet — :DistroTrace on`
   (`traceui.report`), хотя лог уже создан. Сообщение вводит в заблуждение.
2. Трейс по умолчанию выключен и требует **двух команд** (`on`, потом `report`) —
   для потребителя после инцидента это не «одна кнопка, почему тормозит».

**ВЫВОД:** «почему тормозит» как продукт существует (`:ConfigHealth` + `:DistroDiag` +
`:DistroTrace`), но требует знания трёх разных команд и не собирает вывод в одно место.
Формулировка «не работает как задумано» **не подтверждается** — механика работает;
недостаток в удобстве и Discoverability.

---

## 8. ВЕРДИКТ ПО ЗРЕЛОСТИ

### Уровень: **«можно с оговорками»** — но оговорки блокирующие именно для Windows/HDD

Не «нельзя»: кодовая база зрелая, всё, что я прогнал, работает. Не «можно отдавать
потребителю»: при��елитель не справится без сопровождения.

### 8.1 Блокеры по приоритету

| # | Приоритет | Блокер | Доказательство |
|---|---|---|---|
| 1 | **P0** | Нет парсеров на голом клоне: `pack/distro/parser/` пуст (`.gitkeep`), `.gitignore:12` игнорирует `*.so`, а установленные 46 `.so` лежат в `~/.local/share/nvim/site/parser` **вне репозитория**. Нет автобустрапа. Первый запуск = **нет подсветки синтаксиса** | `ls pack/distro/parser/` → пусто; `:DistroParsers` показывает 21 установленный, но не в репо; grep `ensure_installed` → только `treesitter.lua:27` |
| 2 | **P0** | Нет пользовательской документации. README — чужой проект, docs — контракты для разработчиков | §2.2 |
| 3 | **P0** | Windows: сборка парсеров через MSVC `cl` с gcc-флагами, с пометкой автора «may need tuning». Нет подсветки = нет продукта | `distro/treesitter.lua:69-70` |
| 4 | **P1** | Нет which-key из коробки при 187 хоткеях и отсутствии `:help` | `manifest.lua:103` + `ls pack/` |
| 5 | **P1** | Нет команды «поставить всё»: gopls/golangci-lint/парсеры — 4 ручных шага | §5.3 |
| 6 | **P1** | Ложный ERROR «missing required: unzip» на чистой Windows | `health.lua:49` vs `install.lua:58-64` |
| 7 | **P2** | Startup 486ms на macOS/SSD — провал по собственному порогу (>300ms) | `:ConfigHealth` живой вывод |
| 8 | **P2** | smoke-test check 4 не может уронить 4 из 25 команд | §1.6 |
| 9 | **P2** | 106 мёртвых каталогов `site/lazy` у мигрирующих; автоочистки нет | `distro/ui.lua:488` |
| 10 | **P3** | Косметика: дубли `pc/pp/pr` (=`ps/pl/pu`), двойное объявление `:DistroDiag`, вводящее «No trace log yet» | §1.5, §3.2, §7.1 |

### 8.2 Что сделано хорошо (владелец спрашивал про возможности)

1. **Zero-auto-network выдержан честно.** Ни одного автоскачивания; consent-гард
   `install.lua:38-48` refuse-ит без `user_confirmed`, а в headless ещё и без `--yes`.
   Для потребителя с HDD и корпоративным интернетом это ровно то, что нужно.
2. **Плагины вендорены в репозиторий.** `git clone` → работает офлайн. `pack/distro/*`
   = 24+2 на месте, health: «26 plugins installed, no errors».
3. **Два eager-плагина.** Всё остальное по триггерам; dap и lint убраны с filetype-триггеров
   осознанно, с комментарием почему (`manifest.lua:55-61`).
4. **Eager-удаление `grn/grr/gri/gra/grt`.** Проверено: голый `gr` не ждёт timeoutlen.
   Это редкая внимательность к UX.
5. **Слабый ПК — не только турбо-флаг.** `weak_hw` с реальными осями, автоопределение
   профиля в диагностике, три уровня treesitter (`:TreesitterTier`), tier-aware folds,
   large-file гард (10k строк / 1024 KB), дебаунш codelens, отложенный attach gitsigns.
6. **Заглушки не врут.** `:Oil` на неустановленном плагине объясняет, что делать, вместо E492.
7. **Диагностика честно говорит «НЕ ИЗМЕРЕНО».** `diag.lua:89` — «NOT MEASURED:
   %LOCALAPPDATA% not set». Редкая и ценная черта.
8. **Windows учтён в коде, а не только в README.** cmd.exe-квотинг, `NUL`, win32yank,
   PowerShell, `%USERPROFILE%`/`%APPDATA%`, findstr-фолбэк для `:grep`, `chmod` с
   win32-гардом.
9. **CI и smoke-тест существуют и зелёные** (7/7 на быстром прогоне).

### 8.3 Что нужно, чтобы было «можно отдавать»

Минимум три вещи, по убыванию важности:
1. Закоммитить или автоустановить парсеры (сделать P0 закрытым).
2. Написать **один** README для человека: 30 ключевых хоткеев, `:ConfigHealth` как первый шаг,
   «если нужен Go — 4 шага установки», «если тормозит — `:DistroDiag`».
3. Починить MSVC-путь для парсеров и убрать `unzip` из required в health.

Пункты 1 и 2 — не код, а онбординг; без них всё остальное не имеет значения для
потребителя, который открывает клон первый раз.

---

## Приложение: что осталось НЕ ИЗМЕРЕНО

- Любые числа на Windows, HDD или слабом CPU. Все измерения — macOS 26.3 arm64, SSD, APFS.
- Реальное время старта на HDD. 486ms на SSD — нижняя граница.
- Работа всех 25 команд в интерактивном TUI (`:Distro`, `:DistroBinaries`, `:DistroTrace open`,
  `:DistroBenchUI`) — я проверял headless, где float-окна не рисуются.
- Установка плагина/парсера/бинарника через сеть (согласованная задача — только чтение;
  consent-гард я не обходил).
- Поведение `gopls`/`golangci-lint` на HDD.
- `msvc`/`cl`-сборка парсеров, zip-распаковка bsdtar под Windows, `make` на Windows.
