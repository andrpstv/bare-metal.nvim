# ФАЗА 1 — DISCOVERY / ANALYSIS (read-only)

Дата: 2026-09-25 · Репозиторий: `/Users/16prom1/.config/nvim`
Ни один файл конфигурации не изменён. Единственная запись — этот документ.

Метки: **FACT** (прочитано/измерено), **HYPOTHESIS** (гипотеза), **CORRELATION** (наблюдаемая связь без причинности).

---

## 1. Окружение

| Параметр | Значение | Метка |
|---|---|---|
| Neovim | `NVIM v0.11.4`, Release, LuaJIT 2.1.1753364724 | FACT |
| OS | Darwin 25.3.0, kernel arm64, xnu-12377 | FACT |
| CPU / RAM / cores | Apple M1 Pro / 16 GiB / 10 | FACT |
| Shell | zsh | FACT |
| ФС репозитория | `/dev/disk4s1` (APFS, Data volume), 726 GiB, 58% used | FACT |
| Репозиторий | `/Users/16prom1/.config/nvim` (vendored `pack/distro/opt/*`, 4889 файлов) | FACT |
| HEAD | `6fa6263c8f1c829d10fc4f0de31bcdb96c433cdb` — `perf(P2): load gitsigns on BufReadPost instead of CursorHold` | FACT |
| Рабочее дерево | **грязное**: `M init.lua, lua/core/event.lua, lua/core/init.lua, lua/core/go.lua, lua/distro/bench*.lua, loader.lua, keymap/statusline.lua, completion/lsp.lua, ui/gitsigns.lua, themes/black-metal-khold.lua`; новые: `lua/core/turbo.lua`, `scripts/interactive-bench.{lua,sh}`, `docs/distro/10-largefile-analysis.md` | FACT |

FACT: HEAD-коммит и незакоммиченные изменения — это в точности WIP-набор «turbo» (см. §5). Любое измерение по умолчанию отражает WIP-состояние, а не последний коммит.

---

## 2. Карта архитектуры

FACT `init.lua:19`: единственная точка входа — `require("core")`.
FACT `init.lua:14-17`: turbo-флаг вычисляется **до** `require("core")`; `NVIM_DISTRO_SYNC=1` имеет приоритет и выключает turbo.
FACT `lua/core/init.lua:238-294` `load_core()`: порядок `options → event → distro.setup → keymap → pairs/format_on_save → theme → background → commands`.
FACT `lua/core/distro.lua:6-9`: `distro.loader.boot()` + `distro.init.setup()`.

### Менеджер плагинов

FACT: **lazy.nvim отсутствует** — свой загрузчик `lua/distro/loader.lua`, вендоренные плагины в `pack/distro/opt/` (26 штук, `lua/distro/manifest.lua:9-58`).
FACT `loader.lua:39-70` `pack_subtree`: рекурсивный `packadd` deps-first (фаза 1, только rtp).
FACT `loader.lua:74-113` `finish_subtree`: ручной `source_after` + `require(config)` deps-first (фаза 2).
FACT `loader.lua:139-155` `source_after`: `fs_stat(dir/after)`, затем `vim.fn.glob(...)` и `luafile`/`source` — **на каждый load**.
FACT `loader.lua:16-18` `is_present`: `uv.fs_stat` на каждый manifest-entry при каждом `kick` (≈34 стата на boot-цикл).

### Стратегия lazy-loading (manifest)

FACT `manifest.lua:11-12` — eager (`kind="start"`): `black-metal-theme-neovim`, `nvim-web-devicons`.
FACT `manifest.lua:248` (loader) — все `kind != "start"` получают либо `event`-autocmd, либо `ft`-autocmd, либо cmd-stub.

| Плагин | Триггер | Тип дефера | Строка |
|---|---|---|---|
| gitsigns.nvim | `BufReadPost` | `defer_idle` | manifest.lua:14 |
| nvim-lspconfig | `BufReadPre`,`BufNewFile` | `defer_idle` | :16 |
| nvim-cmp + 7 deps | `InsertEnter`,`CmdlineEnter` | `defer_idle` | :17-28 |
| nvim-treesitter | `BufReadPre` | `defer_idle` **+ `defer_until_idle`** | :42 |
| flash.nvim | `CursorHold`,`CursorHoldI` | — | :44 |
| go.nvim, nvim-lint, nvim-dap(+3) | `FileType` go/gomod/gosum | `defer_idle` | :51-57 |
| mini.nvim, diffview, trouble, plenary | cmd-stub (по требованию) | — | :45-49 |

FACT `loader.lua:313-334`: `VimEnter` + таймер 300 мс — **watchdog**: грузит `nvim-cmp` и синхронно сбрасывает весь `pending` + вызывает `drain_idle()`.
FACT `loader.lua:337-344`: `CursorHold/CursorHoldI/InsertLeave` (once) → `vim.schedule(drain_idle)`.
FACT `manifest.lua:85-95` catalog (telescope, oil, toggleterm, which-key, lualine, ibl, neogit, nvim-tree) — не загружаются на boot; cmd/event-триггеры создаются, но `M.kick` для catalog с отсутствующим плагином выходит сразу (`loader.lua:207-209`).

---

## 3. Аудит autocmd (полный инвентарь)

Источники: `grep -rn "create_autocmd|create_augroup" lua/ init.lua` (результат приложен дословно в §3-таблицах). Всего **~45 регистраций** в ~22 augroup.

### 3.1 Горячие события (высокая частота)

| Событие | Файл:строка | Работа | Риск |
|---|---|---|---|
| `WinEnter,BufEnter,InsertLeave` | core/event.lua:178-182 (vimscript) / :241-257 (turbo Lua) | `cursorline` вкл | FACT: на BufEnter; turbo-вариант с ранним return |
| `WinLeave,BufLeave,InsertEnter` | core/event.lua:183-187 / :258-274 | `cursorline` выкл | то же |
| `CursorMoved` | completion/signature.lua:306 | re-arm сигнатуры | FACT: высокочастотное |
| `CursorMovedI` | signature.lua:266 | автоскрытие сигнатуры | FACT: на каждый ввод |
| `InsertCharPre` | signature.lua:223 | signature help | FACT: на каждый символ |
| `ModeChanged` | keymap/statusline.lua:266 | `redrawstatus` | FACT: принудительный redraw на смену режима |
| `BufEnter` | core/event.lua:5 (NvimTreeAutoClose) | `winlayout()` + `confirm quit` | FACT: `confirm` — блокирующий prompt |
| `BufEnter` | core/go.lua:111-124 (GoLibRO) | `is_go_lib(path)` regex | FACT: на каждом BufEnter, размер-независимо |
| `BufEnter` | keymap/statusline.lua:151,163 | инвалидация кэшей stl | FACT: тривиально |
| `BufEnter,InsertLeave,BufWritePost` | keymap/completion.lua:160 | вкл/выкл cmp | FACT: на BufEnter |
| `DiagnosticChanged` | statusline.lua:169 | `_stl_count_diags` | FACT: O(диагностик), не O(строк) |
| `DirChanged` ×2 | core/event.lua:89, :102 | `cd` / `edit` | FACT: рекурсия window→global scope |

### 3.2 Открытие/сохранение

| Событие | Файл:строка | Работа | Риск |
|---|---|---|---|
| `BufReadPre,BufNewFile` | core/large_file.lua:17-43 | `uv.fs_stat` + `line_count`; при «large»: `syntax=off, ft=off, swap=off, undofile=off`, `foldmethod=manual`, `cursorline/cursorcolumn/list/spell=off`, `b:lsp_disable` | FACT: **синхронный stat на BufReadPre** |
| `BufReadPost` | core/event.lua:117-129 | `large_file.enforce()` затем mark-restore | FACT: второй порог по строкам |
| `BufReadPre,BufNewFile` | loader.lua (DistroLazy) | kick lspconfig, treesitter | FACT: до определения «large» по строкам |
| `BufReadPost` | DistroLazy | kick gitsigns | |
| `FileType` | loader.lua:294-303 | ft-плагины (go, lint, dap) | FACT: срабатывает **до** `enforce()` |
| `FileType`,`BufReadPost` | configs/editor/treesitter.lua:79-93 | `nvim_list_wins()` → `foldmethod=manual` если tier ≠ full | FACT: скан всех окон на открытие |
| `FileType` ×2 | core/event.lua:21, :199-208 | QClose + `_ft` | тривиально |
| `LspAttach` | core/event.lua:48-83 | keymaps, `lsp.completion.enable(false)`, inlay hints | FACT: `require` внутри колбэка (кэшируемые) |
| `LspAttach`,`LspDetach` | statusline.lua:157 | сброс кэша lsp | тривиально |
| `BufWritePost` | core/go.lua:50-... | organizeImports → update → format | FACT: цепочка LSP-запросов |
| `BufWritePost` | configs/lang/lint.lua:48 | **спавн `staticcheck`/`golangci-lint`** | FACT: процесс на сейв |
| `BufWritePre` | configs/completion/formatting.lua:33 | format-on-save | |
| `FocusGained` | core/event.lua:195 | **`checktime`** — stat по всем буферам | FACT |
| `VimResized` | core/event.lua:197 | `tabdo wincmd =` | |
| `VimLeave` | core/event.lua:190 | `wshada` | |
| `TextYankPost` | core/event.lua:212 | `highlight.on_yank` | тривиально |
| `ColorScheme` | utils/init.lua:45, themes/black-metal-khold.lua:58,197 | палитра | редко |
| `BufWritePost` `$VIM_PATH/*` | core/event.lua:151-154 | `nested source` + `redraw` | FACT: полный пере-source конфига |
| `CursorHold*`,`InsertLeave` (once) | loader.lua:337 | `drain_idle()` | FACT: интерактив-онли |

FACT: `UIEnter` как триггер **не используется нигде**. FACT: `WinScrolled` не используется. FACT: `TextChanged`/`TextChangedI` собственных autocmd нет (только через плагины).

---

## 4. Цепочка открытия БОЛЬШОГО файла

Порядок событий Nvim: `BufReadPre` → `BufReadPost` → `FileType` → `BufEnter` → redraw.

1. **`BufReadPre`** — FACT `large_file.lua:17`: `is_large_file()` делает `vim.uv.fs_stat` по имени. FACT `large_file.lua:11`: `nvim_buf_line_count(bufnr)` на этом этапе ≈ 0 → **порог в 10 000 строк здесь не может сработать**; срабатывает только ветка «>1 MB» (`:5,8`).
2. **`BufReadPre`** (параллельно) — FACT `manifest.lua:16`: lspconfig уже загружен/загружается; FACT `manifest.lua:42`: treesitter поставлен в idle-очередь. Оба запускаются **до** того, как известно, что файл большой.
3. **`BufReadPost`** — FACT `event.lua:120` → `enforce()` (`large_file.lua:49-75`): вторая проверка по `line_count > 10000` (`:50`), ставит `filetype=off`, `swapfile/undofile=false`, `foldmethod=manual`, `vim.treesitter.stop` (`:69`), открепляет всех клиентов (`:71-73`). Возвращает `true` → mark-restore пропускается (`event.lua:121`).
4. **`FileType`** — FACT: срабатывает до `enforce` в коде Nvim, но `filetype` уже принудительно `off` на шаге 1 для >1MB; для файла 12k строк / 397 KB (под 1 MB) ft успевает отработать в полном объёме и быть снесён на шаге 3. Для Go-файла это означает загрузку `go.nvim, nvim-lint, nvim-dap` + 3 deps (manifest.lua:51-57) впустую.
5. **gitsigns** — FACT `manifest.lua:14`: kick на `BufReadPost`, `defer_idle`; FACT `ui/gitsigns.lua:26-30`: `on_attach` возвращает `false` при `b.large_file`; FACT `:52-54`: turbo-путь тоже отбрасывает `large_file`-буферы. Т.е. diff-работа отсечена, но `git`-процесс инициализации уже мог произойти до проверки.
6. **LSP attach** — FACT `event.lua:57-60`: при `b.large_file` клиент немедленно открепляется. FACT: `vim.b.lsp_disable` (`large_file.lua:36,59`) **не читается нигде в конфиге** — это документация, не enforcement.
7. **Folds** — FACT `treesitter.lua:76-77`: глобально `foldmethod=expr`, `foldexpr=nvim_treesitter#foldexpr()`. FACT `treesitter.lua:79-93`: `TreesitterTierFolds` переписывает в `manual`, но только если `ts_tier(buf) ~= "full"`; для `large_file` тир = `"off"` (`:11-13`), так что переписывание происходит — на `FileType`/`BufReadPost`, то есть **после** возможного первого `foldexpr`-прохода по окну. FACT `treesitter.lua:68-72`: `indent.enable=true` (tier full), `disable` при `~= "full"`.
8. **Statusline** — FACT `statusline.lua:263`: `%!v:lua._statusline()` на каждом redraw; внутри — `nvim_buf_get_name`, `fnamemodify`, `_stl_icon` (кэш по расширению), `_stl_human_size` (`getfsize`, кэш по `b:stl_size_tick`), `_stl_get_git_status`, `_stl_get_lsp_names`, `_stl_diag_cache`. FACT: всё кэшировано кроме промахов кэша; **зависимости от размера буфера нет**.
9. **Treesitter highlight** — FACT `treesitter.lua:28-34`: `highlight.enable=true`, `disable` = тир `"off"` или `gitcommit`; `additional_vim_regex_highlighting=false`.

### Что зависит от размера буфера (сводка)

FACT: только три места читают размер:
- `large_file.lua:5-13` — `max_size=1MB`, `max_lines=10000`
- `treesitter.lua:17-22` — `treesitter_full_lines=2000` (settings.lua:179), `treesitter_lite_lines=10000` (settings.lua:181)
- `gitsigns.lua:26` / `event.lua:57` / `go.lua:55` — проверки `b.large_file`

FACT: `settings.load_big_files_faster = true` (settings.lua:76) объявлен, но **нигде не читается** — мёртвый флаг (проверено grep по `load_big_files_faster`).

HYPOTHESIS (средняя уверенность): наибольший вклад в «большие файлы медленнее» даёт не размер, а то, что большие файлы проходят полный путь загрузки плагинов (lspconfig + cmp-цепочка + ft-плагины) до того, как их выключат, плюс единовременный выход на `FileType`-волне; размер влияет косвенно, через то, *какие* пути активируются.

---

## 5. `nvim_list_uis()` / `defer_enabled()` — критично для harness

| Место | Проверка | Поведение |
|---|---|---|
| `loader.lua:164-174` `defer_enabled()` | `NVIM_DISTRO_SYNC=1` → false; `distro_defer=false` → false; **`#nvim_list_uis() > 0`** | HEADLESS = **полностью синхронный путь** |
| `core/init.lua:259-270` | `turbo_on and #nvim_list_uis() > 0` | pairs + format_on_save через `vim.schedule` только в UI+turbo |
| `ui/gitsigns.lua:9-12` | `turbo_on and #uis>0 and NVIM_DISTRO_SYNC~=1` | `auto_attach=false` + ручной attach |
| `themes/black-metal-khold.lua:25-26` | `#uis == 0 or SYNC` | синхронное применение highlight |
| `completion/lsp.lua:43` | только `turbo.is_on()`, **без** проверки uis | ⚠️ статические caps применяются и в headless при `NVIM_TURBO=1` |
| `statusline.lua:216` | `_turbo.is_on()` в hot-path redraw | деградация кэша диагностик |
| `distro/install.lua:49`, `mirror_cmd.lua:81` | `#uis == 0` | интерактивные подтверждения |

FACT `core/turbo.lua:11-19`: `is_on()` — только чтение `vim.env`/`vim.g`, без FS и без `executable()`. Комментарий `:3-4` прямо запрещает кэшировать.

FACT: `distro_defer = true` (settings.lua:283).

**Вывод для harness (важно):** любое сравнение «turbo on/off» в headless **не** эквивалентно сравнению интерактивного поведения для 5 из 7 точек выше. `NVIM_DISTRO_SYNC=1` даёт детерминизм, но полностью глушит `defer_enabled()`. Единственный способ измерить реальные пути — **UI-attached nvim через pty**; в репозитории для этого уже есть заготовка: `scripts/interactive-bench.sh` (комментарий `:5-7` прямо называет `nvim_list_uis() > 0` своей единственной целью) и `scripts/interactive-bench.lua`.

FACT: `scripts/interactive-bench.sh` не закоммичен (untracked) — это заготовка фазы измерений, а не проверенный инструмент.

---

## 6. Гипотеза-дерево (начальная confidence)

Оценки — по чтению кода. Ни одна ветка не измерена в этой фазе.

**H1 — Фиксированная стоимость открытия доминирует; «большие файлы» — конфоунд состава плагинов.**
Confidence: **HIGH**.
Основание: ~45 autocmd-регистраций, eager-загрузка 2 плагинов, до 8 плагинов на `FileType=go`, deferred-подсистема с watchdog на 300 мс — всё это размер-независимо. Детерминированный «след» — присутствие `FileType`-волны, а не числа строк.
Фальсификатор: измерить warm-open в UI-сессии для 1k и 12k LoC. Если warm large ≈ warm small → H1 подтверждена, посылка о размере неверна.

**H2 — `BufReadPre`-гейт по строкам мёртв; большие файлы платят полную загрузку плагинов и затем стрипаются.**
Confidence: **HIGH (как дефект)**.
Основание: `large_file.lua:11` на `BufReadPre` видит пустой буфер; h2_bundle.go-подобный файл (12k строк, 397 KB) ниже 1 MB → не детектится на первом шаге; `lspconfig` kick (`manifest.lua:16`) и `FileType`-плагины уже произошли. Гипотеза подтверждена наличием в репозитории несохранённого WIP и предыдущим отчётом `docs/distro/10-largefile-analysis.md` §4, который замерял тот же эффект.
Фальсификатор: временно заменить гейт на «первые 64 KB + подсчёт `\n`»; если 12k-файл всё равно тянет lspconfig/cmp — причина не в гейте, а в самих `BufReadPre`-хуках.

**H3 — 300-мс watchdog переводит отложенную работу в синхронный пик.**
Confidence: **MEDIUM-HIGH**.
Основание: `loader.lua:316-334` — на `VimEnter`+300 мс `M.load("nvim-cmp")`, затем синхронный сброс всего `pending` и `drain_idle()`, что обходит собственный замысел «не парсить при наборе» (`loader.lua:190-191`, `232-234`).
Фальсификатор: в UI-сессии замерить кривую задержки до первого нажатия; нейтрализовать сброс очереди в scratch-копии. Нет улучшения → H3 опровергнута.

**H4 — gitsigns — единственный действительно размер-зависимый внешний процесс; turbo-T3 его откладывает, но с дефектами порядка проверок.**
Confidence: **MEDIUM**.
Основание: `ui/gitsigns.lua:47-59` — фиксация `gitsigns_deferred` происходит **после** гардов `large_file`/`executable("git")` (в отличие от комментария `manifest` и `event.lua:51-60`), т.е. порядок в WIP-версии обратный ожидаемому и отброшенный буфер не должен помечаться выполненным — но `:52-54` этот случай покрывает. Остаточный риск: `executable("git")` вызывается на каждом срабатывании `CursorHold(CursorHoldI)/InsertLeave/BufWritePost` до первого успеха.
Фальсификатор: счётчик вызовов `executable` за 5 с idle в UI; ожидание — резкий рост при отсутствии git в PATH.

**H5 — `DirChanged`×2 вызывает каскад `cd`/`edit`; размер-независим, но усиливает любую открывающую волну.**
Confidence: **LOW-MEDIUM**.
Основание: `event.lua:89-111` — window-scope → глобальный `cd` → повторный `DirChanged`; при `filetype=netrw` — вложенный `edit`.
Фальсификатор: счётчик срабатываний `DirChanged` во время открытия большого файла.

**H6 — Statusline/диагностики — постоянный, а не размер-зависимый налог.**
Confidence: **LOW** (как объяснение симптома).
Основание: `statusline.lua:184-261` весь кэширован; единственный неконстантный путь — промах `_stl_diag_cache` (`:214-223`), и turbo-ветка его глушит.
Фальсификатор: `vim.o.statusline="%f"` и повторный замер.

**Ранжирование:** H2 > H1 > H3 > H4 > H5 > H6.

---

## 7. Фальсифицируемые эксперименты

### E1 (по H1) — размер-зависимость в тёплой UI-сессии
- Гипотеза: при прогретых плагинах open-latency плоска по размеру.
- Метрика: мс до `BufReadPost`+первый paint, warm-сессия, 1k vs 12k vs 50k LoC, n≥10, min/median.
- Изоляция: `scripts/interactive-bench.sh` в UI-pty; плагины прогреты одним предыдущим `:edit`; `NVIM_TURBO=0` и `=1` как отдельные прогоны.
- Ожидание (H1): разница <20%.
- Опровержение: 12k ≥2× медленнее 1k → H1 понижена, H2/H3 становятся первичными.

### E2 (по H2) — мёртв ли line-count гейт на BufReadPre
- Гипотеза: `is_large_file` не может увидеть line count на `BufReadPre`.
- Метрика: `b:large_file` сразу после BufReadPre (временно через `nvim_create_autocmd` в probe-скрипте, без правки конфига) для 12k/397KB файла.
- Изоляция: `NVIM_DISTRO_SYNC=1`; без turbo.
- Ожидание: `large_file == false` на BufReadPre, `true` на BufReadPost.
- Опровержение: `true` на первом шаге → гейт работает и H2 (как дефект) неверна.

### E3 (по H2) — кто именно грузится впустую
- Гипотеза: большой Go-файл тянет lspconfig/cmp/go-плагины до стрипа.
- Метрика: снимок `require("distro.loader").loaded` на BufReadPost + на +1000 мс.
- Изоляция: headless, `NVIM_DISTRO_SYNC=1`.
- Ожидание: в `loaded` есть `nvim-lspconfig`, `nvim-cmp`, `go.nvim`, при `b:large_file==true` и `filetype=="off"`.
- Опровержение: список пуст/минимален → waste-гипотеза H2 опровергнута.

### E4 (по H3) — 300-мс watchdog
- Гипотеза: таймер превращает отложенное в синхронный пик ~300 мс после входа.
- Метрика: кривая задержки ввода в UI на 0/100/300/1000 мс; отдельно время `M.load("nvim-cmp")`.
- Изоляция: `NVIM_DISTRO_SYNC=1` полностью убирает `defer_enabled()` → **не подходит**; нужен UI без флага. Сравнить `distro_defer=true/false` (`settings.lua:283`).
- Ожидание (H3): заметный пик ровно в окне ~300 мс, исчезающий при `distro_defer=false`.
- Опровержение: плоская кривая → H3 опровергнута.

### E5 (по H4) — стоимость `executable("git")` на горячем событии
- Гипотеза: `executable()` вызывается многократно на CursorHold/InsertLeave.
- Метрика: счётчик вызовов за 5 с idle с `git` в PATH и без.
- Изоляция: UI-сессия, turbo ON (иначе ветка `turbo_defer` не регистрируется, `gitsigns.lua:39`).
- Ожидание (H4): десятки вызовов, пока буфер не помечен `gitsigns_deferred`.
- Опровержение: 1 вызов на буфер → H4 понижена.

### E6 (по H5) — каскад DirChanged
- Гипотеза: `cd`/`lcd` во время открытия вызывает вложенные `edit`.
- Метрика: счётчик `DirChanged` (scope) + `BufReadPost` во время открытия большого файла в репозитории.
- Изоляция: временно переопределить группу `CdFollow` пустой (в probe, не в конфиге).
- Ожидание (H5): без CdFollow счётчик падает, вложенных `edit` нет.
- Опровержение: счётчик 0–1 и без правки → H5 опровергнута.

### E7 (по H6) — statusline-налог
- Гипотеза: `_statusline()` даёт постоянный, но не размер-зависимый вклад.
- Метрика: время 100 × `redraw!` при текущем statusline vs `vim.o.statusline="%f"`.
- Изоляция: одна переменная, одна сессия, плагины идентично прогреты.
- Ожидание: 2–10 мс/100 redraw, не коррелирует с размером.
- Опровержение: разница с размером буфера >50% → H6 переходит в primary.

### E8 (по H2 vs H1, приоритетная) — интерактивная кривая после paint
- Гипотеза: реальная «медленность больших файлов» живёт в post-paint отложенной работе.
- Метрика: на t = 0/100/300/1000 мс после `BufReadPost` фиксировать `vim.tbl_keys(loader.loaded)`, `#vim.lsp.get_clients({bufnr=0})`, `vim.treesitter.get_parser(0)`, `vim.b.gitsigns_status_dict ~= nil`; отдельно задержка ввода.
- Изоляция: только UI-pty; сравнение 1k vs 12k LoC и `NVIM_TURBO=0/1`.
- Ожидание (H2/H3): ступень на 300 мс, растущая с числом строк.
- Опровержение: кривая плоская и равная для 1k/12k → симптом не про post-paint, H2/H3 закрыты, остаётся фиксированная стоимость H1.

---

## 8. Ограничения и что осталось за фазой

- Ничего не измерялось в этой фазе (read-only). Все проценты/мс отсутствуют намеренно.
- Headless-бенчи не покрывают ни один из `defer`-путей (§5) — E4 и E8 требуют UI-pty.
- `docs/distro/10-largefile-analysis.md` (untracked) содержит headless-замеры предыдущей фазы; его выводы я перепроверил по коду и они согласуются с H1/H2/H3 выше, но его таблицы измерений к этой фазе не относятся и должны воспроизводиться на текущем WIP-состоянии дерева.
- Не проверено: реальная стоимость gopls на 12k LoC, поведение тиров treesitter на буфере 2k–10k строк, эффект статической `TURBO_CMP_CAPS` (`completion/lsp.lua:21-41`) на реальные capabilities gopls.
- Файлы не изменялись; git-состояние не трогалось. Изменён только этот документ.
