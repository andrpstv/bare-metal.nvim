# Разработка bare-metal.nvim: карта для людей и AI-агентов

Короткие правила и инварианты — в [`../CLAUDE.md`](../CLAUDE.md). Здесь — где что лежит, как оно
связано и как добавлять новое. Документ помогает **найти** код; поведение подтверждай чтением
исходника — шапки модулей (`-- модуль — назначение` + «почему свой») обычно отвечают быстрее всего.

Все пути и имена ниже сверены с кодом на 2026-10-12. Пометка *(не проверено)* — вывод без проверки.

## 1. Слои

| Слой | Где | Ответственность |
|---|---|---|
| Вход | `init.lua` | проверка nvim ≥ 0.12.5, env-флаги `NVIM_PERF_DEFER`/`NVIM_PERF_LEAN` (+ deprecated-алиасы), `require("core")` |
| Ядро | `lua/core/` | `init.lua: load_core()` — порядок старта; `settings.lua` (+ `user.settings`), `options.lua`, `event.lua` (автокоманды, LspAttach, подключает `core.go`, `core.large_file`, `core.external`), `perf.lua` (`:PerfDefer*`/`:PerfLean*`), `select.lua` (нативный `vim.ui.select/input`), `pairs.lua`, `health.lua` (`:checkhealth core` = `:ConfigHealth`) |
| Пакеты | `lua/distro/` | `manifest.lua` (источник правды), `loader.lua` (packadd + ленивые триггеры, без сети), `install.lua` (единственный curl/tar), `lock.lua` (`distro-lock.json`), `init.lua` (все `:Distro*`), `ui.lua`, `tools.lua`, `treesitter.lua`, `mirror*.lua`, `setup.lua`; диагностика: `bench*`, `diag`, `trace*` |
| Конфиги плагинов | `lua/modules/configs/<группа>/<имя>.lua` | вызываются loader'ом по полю `config` манифеста; `modules/utils/init.lua` — `load_plugin`, `extend_config`, `register_server`, `gopls_found` |
| LSP | `modules/configs/completion/lsp.lua` + `servers/<name>.lua` | для каждого `settings.lsp_deps`: есть бинарь → пресет `servers/<name>.lua` мёржится и регистрируется; нет → notify и пропуск |
| Свои инструменты | `lua/dev/` | Go-воркфлоу и общие утилиты без плагинов (таблица в §4) |
| Хоткеи | `lua/keymap/` | `init.lua` подключает подмодули; `ru.lua` первым (оборачивает `vim.keymap.set` для RU-раскладки) |
| Пользователь | `lua/user/` (gitignored), шаблон `lua/user_template/` | `user.settings`, `user.options`, `user.event`, `user.keymap.*`, `user.configs.<plugin>`, `user.configs.lsp`, `user.configs.dap` |
| Вендор | `pack/distro/{start,opt}/` | код плагинов; не править руками — обновление через manifest + `:DistroUpdate` |

## 2. Старт и ленивая загрузка

```
init.lua → core/init.lua:load_core()
  createdir, leader, gui/clipboard/shell(Windows: pwsh) →
  core.options → core.event → core.distro.setup()
                                ├ distro.loader.boot()   packpath, kind=start плагины,
                                │                        автокоманды event/ft, cmd-стабы, idle-preload
                                └ distro.init.setup()    команды :Distro* (единственный вход в сеть)
  → keymap → core.select → pairs + format_on_save (под perf_defer — через vim.schedule)
  → тема → term_guard → :ConfigHealth/:Tutor → core.perf.setup()
```

`loader.load(name)` — **единственная** точка активации плагина: идемпотентна, защищена от
циклов, учитывает `settings.disabled_plugins`, отсутствующий плагин → notify без загрузки.

Триггеры записи манифеста (`loader.boot`, `loader.kick`):
- `kind = "start"` — грузится на старте (сейчас только тема и devicons);
- `event` / `ft` → `kick()`; с `defer_idle` — через `vim.schedule`, с `defer_until_idle` — в
  очередь до первого `CursorHold`/`InsertLeave`;
- `cmd` → стаб-команда, загружает синхронно при вызове;
- без триггеров (например `nvim-dap`) — только явный `loader.load()` из кода (`dev.debug.ensure()`).

Отложенность зависит от `core.perf.defer_on()`; `NVIM_DISTRO_SYNC=1` и headless — синхронно
(детерминизм для скриптов). Подробности механики: `docs/distro/09-async-startup.md`.

## 3. Куда смотреть по типу задачи

| Задача | Начни с | Образец | Тесты |
|---|---|---|---|
| Новый плагин | `distro/manifest.lua` (контракт полей — `docs/distro/01-architecture.md`) | запись `gitsigns.nvim` / `diffview.nvim` | `regress-gitui.lua` (загрузка по cmd) |
| Конфиг плагина | `modules/configs/<группа>/` | `ui/gitsigns.lua` | — |
| LSP-сервер / пресет | `completion/lsp.lua`, `servers/` | `servers/gopls.lua` | `regress-lsp.lua`, `regress-gowatch.lua` |
| Go: тесты / бенчи | `dev/test.lua` (`run`, `_execute`) | — | `regress-test-names.lua` |
| Go: build / run | `dev/build.lua` (`pkg_dir`) | — | `regress-pkg.lua` |
| Go: модули | `dev/gomod.lua` | — | `regress-gomod.lua` |
| Отладка | `dev/debug.lua`, `dev/inspect.lua`, `configs/tool/dap.lua` | — | `regress-dbg-cycle.lua`, `regress-dbg-running.lua`, `regress-dbgui.lua` |
| Format on save | `completion/formatting.lua`, `core/go.lua` | — | `regress-format.lua` |
| Select/input UI | `core/select.lua` | — | `regress-select.lua` |
| Внешние изменения файлов | `core/external.lua` | — | `regress-external.lua` |
| Агенты (sidekick) | `keymap/agent.lua`, `modules/configs/tool/sidekick.lua`; план — `docs/distro/34-agent-workflow.md` | — | `regress-sidekick.lua` |
| Ревью правок агента | `dev/agent.lua` (`start`, `quickfix`, `_parse_diff`) | — | `regress-agent.lua` |
| Хоткей | `keymap/<область>.lua`, справка `keymap/leader_help.lua` | `keymap/dev.lua` | `regress-keymaps.lua` (коллизии), `regress-gitmaps.lua`, `regress-y.lua` |
| Настройка | `core/settings.lua` (комментарий у каждого ключа) | — | — |
| Сеть / установка | `distro/install.lua` (`require_consent`), `distro/tools.lua` | — | ручные кейсы `docs/distro/04-cases-matrix.md` |
| Производительность | `core/perf.lua`, `distro/trace*.lua` | — | `scripts/*-bench.*`, `:DistroBench`, SLO в `docs/distro/11-speed-program.md` |
| Большие файлы | `core/large_file.lua` | — | анализ `docs/distro/10-largefile-analysis.md` |

## 4. Свои инструменты (`lua/dev/`) и их общий шаблон

| Модуль | Делает | Вместо |
|---|---|---|
| `test` | `go test -json` → quickfix + summary, rerun-failed, coverage-знаки | neotest |
| `build` | `go build`/`go run` пакета текущего файла | `:GoBuild`/`:GoRun` без пакета |
| `gomod` | настоящий `go mod tidy` в корне модуля | `:GoModTidy` |
| `debug`, `inspect` | nvim-dap + `dlv dap`, своё окно Frames/Scopes/Watches | nvim-dap-ui, nio, dap-go |
| `project` | корень (go.work/go.mod/.git), сессии, автосейв | project-плагины |
| `terminal` | постоянный `:terminal` на проект | toggleterm |
| `replace` | rg → quickfix → confirm → apply | grug-far |
| `refactor` | LSP call hierarchy, selection range | — |
| `agent` | сессия ревью: база `git stash create`, gitsigns base, ханки → quickfix, Diffview | — (нет агентно-независимых аналогов) |

Общий шаблон (по `test`/`build`/`gomod`): шапка с «почему свой» → `local M = {}` → внешние
процессы через `vim.system(argv, { cwd = ... }, cb)` + `vim.schedule` → результат в quickfix,
итог в `vim.notify("[модуль] ...")` → вызов из `keymap/*.lua` через `require` внутри обработчика.
Тестируемая логика вынесена в функции модуля (иногда с префиксом `_test_*`/`_`), чтобы
regress-скрипт мог дернуть её без UI.

## 5. Тесты и проверка

Фреймворка нет — headless-скрипты `scripts/regress-*.lua` с локальной `check(desc, cond)`,
печатают `OK`/`FAIL`, код выхода 1 при провале; `vim.notify`/`vim.system` подменяются заглушками.

- **Чистые unit** (без конфига, без сети): `nvim --headless --noplugin -u NONE --cmd "set rtp+=$PWD" -l scripts/regress-<x>.lua`
  — перечислены в `smoke-test.sh`, секция 3c.
- **С полным конфигом**: `nvim --headless -c "luafile scripts/regress-<x>.lua" -c 'qa!'` — секция 3d.
- **Набор**: `./scripts/smoke-test.sh [--quick]` → `RESULT: PASS`. Без сети, установок и git.
- **Релиз**: `./scripts/release-check.sh` — приватные файлы не в git + полный smoke.
- `stylua`/`luacheck` локально не установлены и не вызываются скриптами — запускать вручную при наличии.

Новый скрипт: скопируй ближайший по типу (`regress-pkg.lua` — unit с заглушкой `vim.system`;
`regress-keymaps.lua` — с конфигом), добавь имя в список нужной секции `smoke-test.sh`.

## 6. Кроссплатформенность

Подтверждено в коде: Windows-shell (pwsh, `-NoProfile`, `shellslash`) и clipboard по ОС — в
`core/init.lua`; флаги ОС — `core/global.lua`; подсказки установки по ОС — `distro/tools.lua`;
установщики `scripts/install.sh` и `scripts/install.ps1`. Правила для нового кода: пути через
`vim.fs.joinpath`/`vim.fs.normalize`, абсолютный путь проверять и на `^%a:` (см. `dev/test.lua`),
не предполагать POSIX-shell — внешние команды запускать списком argv через `vim.system`.

## 7. Добавление фичи — порядок

1. Есть ли уже механизм (таблица §3, `core.select`, quickfix, `dev.*`)? Используй его.
2. Нужен плагин → запись в manifest с ленивым триггером + конфиг в `modules/configs/`; установка
   только через `:DistroInstall` (с подтверждением). Свой модуль → `lua/dev/` или `lua/core/` по шаблону §4.
3. Хоткей — в соответствующий `keymap/*.lua`, проверить коллизии `regress-keymaps.lua`.
4. Регресс-скрипт + строка в `smoke-test.sh`; запись в `CHANGELOG.md`; при изменении
   пользовательского поведения — `docs/CONSUMER-GUIDE.md`.
5. Если фича меняет стоимость старта/рантайма — замер (`scripts/startup-bench.sh`, `:DistroBench`).

## 8. Остальная документация

- `README.md` — установка, команды, хоткеи (для пользователя).
- `docs/CONSUMER-GUIDE.md` — руководство пользователя.
- `docs/distro/` — контракты distroManager (`00` требования, `01` архитектура, `06` зеркала,
  `09` async-старт, `11` SLO) и рабочие отчёты; `archive-2026-09/` — история, не руководство.
  Индекс: `docs/distro/README`.

## 9. Известные расхождения документации с кодом

Найдены при сверке 2026-10-12, исходники не менялись:

- `docs/distro/01-architecture.md` — счётчики (21+9 vs 25 плагинов + 7 в catalog), `checkhealth distro`
  и `:DistroHealth` (в коде нет; health — `lua/core/health.lua`), экспорт `TOOLS`/`PARSERS`
  (в коде — `tools`, `binaries`, `get`, `get_tool`), список команд неполон, не описаны поля `deps`/`defer_idle`/`defer_until_idle`/`branch`/`catalog`/`desc`.
  Помечено баннером в файле.
- Шапка `lua/keymap/lang.lua` говорит «DAP-стек вырезан», но `dev/debug.lua` работает на nvim-dap.
- `lua/user_template/configs/lsp-servers/` и `dap-clients/` — каталоги-заглушки; кода, читающего
  `user.configs.lsp-servers.*` / `dap-clients.*`, не найдено *(возможно, мёртвый шаблон — не проверено глубже)*.

## Актуализация

Меняешь подсистему — правь её строку в §1/§3/§4 тем же коммитом. Раздел устарел, а времени
нет — добавь пункт в §9 вместо молчаливого расхождения. Отчёты о разовых задачах сюда не
пишутся: им место в `CHANGELOG.md` или `docs/distro/` с датой.
