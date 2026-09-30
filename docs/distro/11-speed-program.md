# Спид-программа: рантайм прежде всего

> Статус: активна. Приоритет зафиксирован решением от 2026-09-29:
> **скорость старта — вторична, скорость рантайма — первична.**
> Клиент простит +20мс старта, но не простит лаг `gd`, мёртвый cmp
> на битом файле и фриз ввода на слабом ПК.
> Ни одна фича в ходе программы не удаляется — режем только синхронность.

Связанные документы: `09-async-startup.md` (механизмы defer),
`10-largefile-analysis.md` (тиры/гард), `08-refactor-plan.md`,
`05-qa-report.md`. Отчёты и замеры по ходу: `docs/distro/speed/` рядом
с этим файлом (`baseline.md`, `reports/C*.md`, заметки в отчётах циклов).

## 1. SLO релиза (все цифры — медианы, машина координатора, nvim 0.12.5)

### Рантайм (P0 — гейт релиза)

| Метрика | Было (2026-09-29) | Цель | Стенд |
|---|---|---|---|
| cmp popup после `.` | надо печатать, задержки | **≤50мс, preselect top-1** | tui-test PTY + `interactive-bench.sh` |
| `gd` тёплый / холодный | иногда лаги, цифр нет | **p50 ≤120мс / ≤800мс** | `:DistroBench`, `measure-cold-definition.lua`, trace |
| `gr` тёплый | иногда лаги | **p50 ≤300мс** | `:DistroBench` |
| cmp на сломанном Go-файле | умирает до рестарта nvim | **авто-recovery ≤2с** | tui-test: сломал→починил→popup |
| ввод/скролл на слабом ПК | не измерено | **ноль фризов >100мс** | `NVIM_PERF_LEAN=1` + tui-test |
| открытие Go 2500 строк до editable | ~138мс | **≤90мс** | `startup-bench.sh`, `runtime-bench.lua` |

### Старт (P1 — не гейт, только не деградировать)

| Метрика | Было | Цель |
|---|---|---|
| холодный старт пустого | ~53мс мед. | ≤60мс мед., не хуже было |
| smoke check 6 | 78/43мс ratio 1x | PASS, лимит 5x |

### Тема ~8мс sync

Осознанно **деприоритизирована**: это стартовая цена, клиент её не чувствует
в рантайме. Async-сплит (`black-metal-khold.lua:43-51` + палитры) — бэклог
Цикла 4, только если Циклы 1–3 закроются с запасом. Kill-switch уже есть:
ось `theme` в `core/perf.lua:182`, sync в headless/SYNC.

## 2. Команда и ритм

- **Perf-lead / координатор** — бюджет мс, гейты в `smoke-test.sh`, сводка циклов.
  Владелец `scripts/*`, `distro/bench.lua`, `trace.lua`.
- **Completion-team** — cmp triggers/sources/recovery.
  Владелец `modules/configs/completion/cmp.lua`, `servers/gopls.lua`,
  `keymap/completion.lua`.
- **Navigator-team (gd/gr)** — warm-путь, gopls-флаги, спаны.
  Владелец `keymap/pick.lua`, `distro/loader.lua`, `bench/diag`.
- **UI-team** — диагностика из settings, статуслайн, netrw, `li/lr`.
  Владелец `lsp.lua`, `keymap/statusline.lua`, `keymap/tool.lua`.
- **Distro-team** — smoke-фикс, доки=факт, установщик, lock-синхрон.
- **QA (tui-test)** — матрица каждого цикла, слабый ПК, Go-сессия (§7).

Ритм цикла: план → работа → замеры → отчёт `docs/distro/speed/reports/C*.md`
(таблица было/стало) → гейт. Гейт: smoke 8/8 + SLO-цикла зелёные +
ноль новых `E492`/трейсбеков в PTY-матрице. Без цифр цикл не закрыт.

## 3. Цикл 0 — базовая линия (0.5 дня)

1. **Починить стенд.** `scripts/interactive-bench.sh`: `gen_go()` пишет корпус
   без `go.mod` → gopls в degraded single-file (`No packages found`),
   замер упирался в 59с-stall. Добавить генерацию `go.mod` + `go.sum`-заглушки
   в `$CORPUS`. Без этого все Go-цифры лгут.
2. **Починить smoke check 4.** Генерация массива даёт `{''ConfigHealth''}` →
   `E5107`, чек всегда PASS; живьём `MISSING LeaderHelp/TreesitterTier`.
   Починить кавычки, фейлить на `E5107/E5113`, добавить 6 `Perf*`-команд,
   явная политика для UI-only (`LeaderHelp`) и lazy (`TreesitterTier`).
3. **Зафиксировать `speed/baseline.md`**: старт мед./мин, file-open small/go5k,
   `gd` cold/warm RTT, cmp popup после `.`, ввод. Три прогона, разброс <15%.

## 4. Цикл 1 — P0 быстрые победы (1–2 дня)

Всё из аудитов, всё с проверкой в PTY:

1. **Codelens deprecated** — `keymap/completion.lua:134,171` (+ `go.nvim/lua/go/lsp.lua:45`
   в вендоре): `vim.lsp.codelens.refresh()` без аргументов сыпет варнинг
   в cmdline на 0.12. Перевести на API 0.12.
2. **`fo → mini.extra`** — `keymap/tool.lua:77`: `oldfiles` живёт в extra,
   не в `mini.pick`. Сейчас `unknown builtin picker`.
3. **`li/lr` мертвы на 0.12** — `:LspInfo/:LspRestart` не создаются
   (early-return в lspconfig при builtin `:lsp`). `li` → `:checkhealth vim.lsp`,
   `lr` → собственный рестарт через `vim.lsp.stop_client` + `edit`;
   плюс глобальный фолбэк без LSP («поставь gopls: …», `:DistroBinaries`).
   README обещает `<leader>li` — сейчас это E492.
4. **`_flash_esc_or_noh` мёртв** — `keymap/helpers.lua:2`: предикат
   `flash.plugins.char.state` всегда truthy, ветка `noh` недостижима.
   Минимум: всегда `noh`.
5. **`_pick_grep_visual` мёртв** — `keymap/pick.lua:342`: брать метки `'<'/'>'`
   вместо `getpos("v")`.
6. **`toggle_format_on_save`** — `completion/formatting.lua:50`: pcall вокруг
   `get_autocmds` (после disable группа удалена → `Invalid 'group'`).
7. **Диагностика из settings** — `modules/configs/completion/lsp.lua:4-9`
   ставит `virtual_text=true` и не читает `settings.diagnostics_virtual_lines/level`.
   Пробросить + severity_sort.
8. **Статуслайн** — `keymap/statusline.lua:124` `%.2g→%.0f` (чинит `2.3e+02k`);
   `%<` (`:236`) правее имени; инвалидация git-кэша по `User GitsignsUpdate`.
9. **Bare `t`-табы** (`ui.lua:27-30` съедают `t{char}`-моушен): перенести на
   `<leader>t*` либо задокументировать как трейдофф. Молча в релиз нельзя.
10. **Мусор**: дубль `:DistroDiag` (`distro/diag.lua:1066`), комменты
    (`core/event.lua:169-174`, `core/options.lua:5`, `core/init.lua:27-30`),
    `dap.lua:1`, `cache/session` (`core/init.lua:7`), `use_ssh=false`
    в `user_template` (сейчас true + perl-костыль в install.sh).

Ожидание: −5..10мс старта бонусом, ноль E492 в матрице.

## 5. Цикл 2 — рантайм-ядро (главный цикл)

### 5a. cmp как в VS Code, только быстрее

Факты (`modules/configs/completion/cmp.lua`): `keyword_length=2` (`:49`),
`preselect=None` (`:43`), `max_view_entries=80` (`:123`), format-функция
на каждый кандидат (`:82-107`: `get_id_snippet` + `get_docstring` + 3×gsub),
`async_budget=2` (`:121`), buffer-источник уже ограничен (`:175-190`),
static fallback caps в `completion/lsp.lua`, gopls debounce 150/250
(`servers/gopls.lua:54-55`).

1. **Триггер `.`**: `keyword_length=1` после trigger-символов (`.`/`:`/`/`),
   2 — для букв; `preselect=item` (top-1 подсвечен, Tab принимает).
   Сейчас `None` = «печатай и выбирай руками».
2. **Resolve-later**: в popup только label/kind; `get_docstring` — для видимых
   топ-N с кэшем по `snip_id` (инвалидация на смену буфера). Снимает главный
   per-keystroke кост `:82-107`.
3. **Источники не режем**, но buffer — от 3 символов и не на больших файлах;
   buffer-скан кэшировать между кейстроками.
4. **Recovery (главный баг цикла)**: watchdog на `LspDetach`/`ClientExit` gopls →
   `notify` + авто-рестарт через API с бэкоффом (макс 3, дальше честная
   подсказка: `:DistroBinaries`). Расширить `is_file_buffer`-гард на состояние
   «клиент умер». Тест: битый Go → правим → popup ≤2с без рестарта nvim.
5. **gopls**: дефолт остаётся богатым (фичи!), но codelens — только по
   `<leader>cl` (убрать refresh на BufEnter/InsertLeave), semanticTokens — off
   в lean, `directoryFilters` — исключить `vendor/node_modules` (тонет `fw`).

### 5b. Тёплый gd/gr

Путь: keymap → `_pick_ensure` (тянет mini.nvim через loader, до ~121 модуля
холодным) → `mini.pick` → `buf_request` → gopls → jump.

1. **Warm на idle**: предзагрузка `mini.pick`/`mini.extra` на первом idle
   (аналог cmp-warm в `completion/lsp.lua`). Единственный медленный `gd` —
   первый холодный в сессии.
2. **jump1 для definition** (уже) — не показывать пикер ради 1 результата;
   references — пикер с таймаутом и «gopls занят, жду…» вместо фриза.
3. **Спаны** на каждый хоп (`picker:ensure`, `loader:load/mini.nvim`,
   `lsp:definition`, `lsp:references`) — `tracehooks` уже оборачивает `_pick*`,
   добавить недостающие. Следующий «лаг gd» разбирается по `:DistroTrace`.
4. Проверка: `:DistroBench` gd/gr cold/warm + trace-отчёт, p95 в SLO.

### 5c. File-open до editable

1. Тиры (`editor/treesitter.lua:4-20`, `full≤2000`) — проверить границы
   2001/10001 живьём; `:TreesitterTier` стаб вместо E492 до idle.
2. Разобрать `BufReadPre`-агрегат (~12мс): что лишнее синхронно.
   `pairs.setup` + `formatting.configure` уже в schedule — проверить быстрый `:w`
   сразу после open.
3. `updatetime 1000→400-500` только с замером до/после.

## 6. Цикл 3 — слабые ПК и неубиваемость + Go-сессия

1. **Lean-матрица** (tui-test, `NVIM_PERF_LEAN=1` vs full): ввод, `G/gg`,
   `gd`, cmp на большом Go-репо — ноль фризов >100мс. Деградация = качество
   (lite-хайлайт, debounce 250), не отсутствие фич.
2. **Recovery-тесты**: убитый gopls (`kill`), битый `go.mod`, нет `cc/rg/go`
   в PATH — везде хинты (`:DistroBinaries`, `:DistroTools`), Health без трейсбеков.
3. **Go-сессия агента** (обязательно): создать тестовый Go-проект через tui-test,
   импортировать `distro/trace` (`:DistroTrace` + `gd` в его исходники),
   прыгнуть в stdlib (`gy`/definition в `GOROOT/builtin.go`), прогнать хоткеи
   (`gd/gr/gi/K/gs/ga/rn/gO`), кривые кейсы: битый файл, пустой `go.mod`,
   `vendor/`, cgo-файл. Отчёт со скринами/дампами.
4. Не трогать: clipboard/shell-ветки, `is_file_buffer`, large-file — гарды есть,
   только покрыть.

## 7. Цикл 4 — релиз

1. Доки = факт: README 27 команд (smoke проверяет все 27: 21 + 6×`Perf*`);
   гайд без `cmp_defer_caps`/`weak_hw_axes`;
   `lazy-lock.json` удалить/пометить stale (правда — `manifest`+`distro-lock`).
2. Установщик: идемпотентность (не терять `lua/user/` при повторе),
   `XDG_CONFIG_HOME` в sh, честное «sh клонирует / ps1 ставит тулчейн».
3. Deprecated perf-слой (`turbo.lua`/`weak_hw.lua`, дубли команд) — УДАЛЁН
   (было «оставить до major», срезан в C5: env-алиасы живут в perf.lua,
   settings-ключи маппятся; breaking — только имена `:Turbo*`/`:WeakHw*`).
4. Бэклог (только с запасом): тема async-сплит (§0), native fuzzy-фильтр —
   только по spike-критерию «тёплый `ff` на 50k файлов >80мс после Lua-оптов».
   Парсеры и так C, jsregexp компилирован — перепись конфига на C/Rust
   не рассматривается: выигрыш доказанно меньше цены.
5. Гейт: SLO рантайма зелёные ×3 прогона, QA-матрица без FAIL, `git status` чист, тег.

## 8. QA-матрица каждого цикла (tui-test, PTY only)

Хоткеи (~70 по карте keymap-аудита, особое: Tab/cmp, `gd/gr/gi/gy/gw/K/gs/ga/rn`,
Go-группа, `e/E`, Trouble, ханки, сессии, табы/сплиты/терминал) · UI (кадр 1
тёмный, тема после idle, статуслайн в узком окне, netrw туда-обратно, пикеры
включая пустой результат, Trouble doc/workspace, virtual_lines) · Perf (smoke,
bench small/big, `gd` cold/warm, `.`-popup, recovery, lean vs full) ·
Совместимость (без `rg/cc/go/lsp` в PATH, пустые `XDG_*`, повторный install).
