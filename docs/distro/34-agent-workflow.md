# Агентная разработка: план реализации

> Статус: **утверждён 2026-10-12**, к реализации. Контракт фичи: меняешь поведение — сначала правь этот файл.

## Цель

Разработчик открывает CLI-агента (Claude Code, OpenCode, Codex, Gemini, …) в окне рядом с кодом,
отдаёт ему контекст из редактора и **сразу видит и ревьюит** правки агента — одинаково для любого
агента, средствами Vim (quickfix, знаки, diff), без чата внутри nvim.

## Решения

| Вопрос | Решение | Почему |
|---|---|---|
| Окно агента и отправка контекста | **sidekick.nvim** (folke), основной список manifest, ставится `:DistroSetup` | 12 CLI из коробки, плейсхолдеры `{this}`/`{selection}`/`{diagnostics}`/`{quickfix}`, родной TUI агента; snacks не обязателен |
| Ревью правок | **Свой слой** `dev.agent` + `dev.check` | Агентно-независимо (работает по файлам и git); готовых аналогов в просмотренных плагинах нет |
| Модель ревью | После записи: reload (`core.external`) → знаки/quickfix → stage/reset | Масштабируется на многофайловые правки; ревью до записи остаётся в TUI агента |
| Минимум Neovim | **0.12.5** (было 0.11) | sidekick требует ≥ 0.11.2; решено поднять до текущей рабочей версии |
| Префикс хоткеев | `<leader>A…` | Свободен целиком (проверено grep по `lua/keymap/`) |
| Отклонено | claudecode.nvim (Claude-only, жёсткая зависимость snacks), ACP-чаты (agentic/avante: другая парадигма, npm-адаптеры мимо `:Distro*`), push выделения / свой MCP (выгода — одно нажатие, цена — хрупкий протокол или ненадёжный pull) | Пересмотреть push через 2 недели использования, если явная отправка мешает |

## Фазы

Каждая фаза — отдельный коммит: код + `scripts/regress-*.lua` + строка в `smoke-test.sh` +
`CHANGELOG.md` + раздел `docs/CONSUMER-GUIDE.md` + строка `docs/DEVELOPING.md` §3/§4.

### Фаза 0 — спайк sidekick (без коммита в main)

Вендорить во временную ветку, проверить на nvim 0.12.5 / macOS:
1. Вес в `pack/distro/opt/`, грузится ли NES/Copilot-часть без Copilot (не должна — иначе отключить в конфиге).
2. Как отправляется `{this}`/`{selection}`: ссылка `path:lines` или текст; bracketed paste.
3. Встроенный терминал (не tmux/zellij) с Claude и OpenCode; наследуется ли `$NVIM`.
4. Есть ли хук/событие «агент открыт» — для автостарта сессии ревью (иначе старт явным хоткеем).
5. Конфликты с `keymap.ru`, `core.select`, which-key.

**Гейт:** п.1–3 ок → фаза 2 как задумано. Нет → вместо sidekick свой `dev.agent.open/send`
поверх `dev.terminal` (~140 строк: именованные терминалы + bracketed paste).

### Фаза 1 — минимум Neovim 0.12.5

Места (проверено grep): `init.lua` (проверка `has("nvim-0.12.5")` + сообщение), `scripts/install.sh`
(`REQUIRED_NVIM_VERSION`), `scripts/install.ps1`, `scripts/smoke-test.sh` секция 2 (`REQUIRED`),
`README.md` (шапка, таблица требований, установка), `CLAUDE.md`, `docs/DEVELOPING.md` §1.
Проверка: `smoke-test.sh` секция 2 зелёная. Риск: пользователи LTS-дистрибутивов Linux с пакетным nvim 0.11.

### Фаза 2 — sidekick в дистрибутиве

- `lua/distro/manifest.lua`: запись (pin `ref`, `kind = "opt"`, ленивая загрузка по `cmd` / из хоткея через `loader.load`).
- `lua/modules/configs/tool/sidekick.lua`: только CLI-часть, NES выключен, бэкенд — встроенный терминал.
- Хоткеи `<leader>A…` (новый `keymap/agent.lua` или раздел в `keymap/dev.lua`) + `leader_help.lua`:

| Клавиша | Действие |
|---|---|
| `<leader>Aa` | открыть/скрыть агента (выбор CLI) |
| `<leader>As` (n/x) | отправить `{this}` / выделение |
| `<leader>Ap` | выбрать промпт-шаблон |

Проверка: `regress-keymaps.lua` (коллизии), загрузка по команде по образцу `regress-gitui.lua`.

### Фаза 3 — сессия ревью `dev.agent`

- Старт сессии: база = `git stash create` (снимок рабочего дерева, ничего не меняет) или `HEAD`, если чисто;
  запомнить список untracked (`git ls-files --others --exclude-standard`).
- `gitsigns.change_base(base, true)` — знаки показывают только правки агента
  (API есть в вендоренном gitsigns: `actions.lua:802`). Конец сессии — `change_base(nil, true)`, обязательно.
- Ханки сессии → quickfix: `git diff -U0 <base>` (разбор `@@`-заголовков) + новые untracked-файлы целиком.
  Сначала проверить, учитывает ли `gitsigns.setqflist("all")` сменённую базу — если да, свой разбор не нужен.
- `:DiffviewOpen <base>` — полный дифф сессии.
- Принять/откатить ханк — существующие `<leader>gs` / `<leader>gr`.

| Клавиша | Действие |
|---|---|
| `<leader>Ab` | начать сессию / сбросить базу («всё принял») |
| `<leader>Aq` | ханки сессии → quickfix |
| `<leader>Ad` | Diffview от базы |
| `<leader>Ae` | завершить сессию (вернуть базу gitsigns) |

Без git — notify и выход. Проверка: `regress-agent.lua` — argv с заглушкой `vim.system`, разбор
`git diff -U0`, untracked, восстановление базы.

### Фаза 4 — видимость в статуслайне

- ~~`core.external`: `User` autocmd после перезагрузки~~ — не понадобилось: `FileChangedShellPost`
  приходит и на тихую перезагрузку autoread (проверено 2026-10-12), `core.external` не менялся.
- `dev.agent`: счётчик «agent: N files» (`git diff --name-only <base>` + untracked), пересчёт с debounce
  по этому событию и `FocusGained`; без активной сессии — ноль работы.
- `keymap/statusline.lua`: сегмент счётчика.

Проверка: debounce и «нет сессии → нет вызовов git» в `regress-agent.lua`; `regress-external.lua` — событие.

### Фаза 5 — `dev.check`

`go build ./... && go vet ./...` (+ `golangci-lint run ./...`, если установлен) в корне модуля
(`dev.gomod.mod_root`) → quickfix + итог в notify. Шаблон — `dev.build`. Клавиша `<leader>Ac`.
Проверка: `regress-check.lua` по образцу `regress-pkg.lua`.

## Инварианты фичи

- Ноль работы на старте: всё грузится из хоткея/команды; без сессии — ни одного вызова git.
- Сеть не используется (sidekick — только локальные процессы; установка — через `:DistroSetup`/`:DistroInstall`).
- Никогда не меняем рабочее дерево и индекс сами: только чтение git; stage/reset — явным действием пользователя.
- Windows: argv-списки через `vim.system`, пути через `vim.fs`; поведение sidekick на Windows проверить отдельно (вне фазы 0).

## Открытые вопросы (закрываются фазой 0)

- Формат и механизм отправки контекста sidekick; есть ли событие открытия агента.
- Учитывает ли `gitsigns.setqflist` сменённую базу.
- Не грузится ли NES-часть sidekick без Copilot.
