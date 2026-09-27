# bare-metal.nvim

Дистрибутив Neovim для тех, кто пишет код и устал от «красивых, но тяжёлых» конфигов.
Взят за основу Neovim 0.11+, вендорен в репозиторий (без менеджера пакетов на старте)
и устроен так, чтобы редактор открывался быстро, а всё, что лезет в сеть, спрашивало
разрешения заранее.

    nvim --clean            # голый Neovim, ~41 мс
    nvim                    # этот дистрибутив

---

## Что это

Обычная конфигурация Neovim в виде репозитория: `init.lua` — точка входа, всё остальное
лежит в `lua/`. Никакой магии, никаких «рантайм-загрузчиков из интернета».

Три свойства, ради которых он и сделан:

1. **Ничего не скачивается молча.** Плагины лежат в репозитории (`pack/distro/`),
   парсеры и внешние утилиты ставятся только после явного подтверждения.
   В конфиге нет ни одного автоматического сетевого обращения на старте.
2. **Предсказуемый старт.** Тяжёлое (автодополнение, отложенные фичи) подгружается
   не на `:edit`, а на первый `InsertEnter` — первое открытие файла остаётся дешёвым.
3. **Самодостаточность.** `gopls`, линтер, `rg`, компилятор для парсеров не нужны
   для того, чтобы редактор *запустился*, — но нужны для того, чтобы он был полезен.
   Что доставить руками, написано ниже.

## Требования

| Что | Версия | Обязательно |
| --- | --- | --- |
| Neovim | **0.11+** | да |
| macOS / Linux / Windows | — | да |
| `curl`, `tar` | любые свежие | да (ставит и обновляет плагины) |
| C-компилятор (`cc`/`gcc`/`clang`) + `make` | любые | для парсеров treesitter |
| `ripgrep` (`rg`) | любой | ускоряет поиск по проекту |
| Go (`go`) | — | только для Go-разработки |

На Neovim < 0.11 конфиг не грузится: показывается одно понятное сообщение вместо
каскада ошибок. Проверить версию — `nvim --version`.

## Установка

```sh
git clone https://github.com/andrpstv/bare-metal.nvim.git ~/.config/nvim
nvim
```

Windows (PowerShell):

```powershell
git clone https://github.com/andrpstv/bare-metal.nvim.git $env:LOCALAPPDATA\nvim
nvim
```

Либо готовым скриптом — он сам сделает бэкап, если конфиг уже есть:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/andrpstv/bare-metal.nvim/main/scripts/install.sh)
```

Скрипт клонирует репозиторий в `~/.config/nvim`. Другой репозиторий:

```sh
NVIM_DISTRO_REPO=myfork/my-config ./scripts/install.sh
```

### Первый запуск

1. Откроется дашборд. Плагины уже на месте — сеть не нужна.
2. Проверьте окружение: `:ConfigHealth` (бинарники, LSP, тема, ключи).
3. **Поставьте парсеры treesitter.** Без них нет подсветки синтаксиса:

   ```vim
   :DistroParsers --all
   ```

   Спросит подтверждение, скачает и соберёт недостающие. Нужен компилятор.
   Читать про это стоит до того, как вы откроете первый файл.
4. Дальше — `:Distro`, если понадобится доставить плагин из каталога.

## Что нужно доставить руками

Ничего из этого не ставится автоматически.

### Языковые серверы (LSP)

Редактор работает без них, но без них нет автодополнения, goto и диагностики.

| Язык | Сервер | Установка |
| --- | --- | --- |
| Go | `gopls` | `go install golang.org/x/tools/gopls@latest` |
| Lua | `lua-language-server` | [см. инструкцию](https://github.com/LuaLS/lua-language-server#installation) |
| Bash | `bash-language-server` | `npm i -g bash-language-server` |
| JSON / JSONC | `vscode-json-language-server` | `npm i -g vscode-langservers-extracted` |
| HTML | `vscode-html-language-server` | `npm i -g vscode-langservers-extracted` |
| C / C++ | `clangd` | `brew install llvm` / `apt install clangd` |
| Python | `pylsp` | `pip install python-lsp-server` |
| Dart | `dartls` | идёт с Dart SDK |

Проверить, что сервер подхватился: `<leader>li` в буфере с этим типом файла.

### Линтер

```sh
go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
```

Без него Go-линт молча выключен (одно уведомление при загрузке).

### Форматировщик

Формат-on-save сам выбирает доступный: `gofumpt`/`goimports` для Go, `stylua` для Lua,
`shfmt` для shell. Поставьте нужный — иначе подсветит, но не отформатирует.

### Парсеры treesitter

```vim
:DistroParsers            # что уже стоит
:DistroParsers go         # один язык
:DistroParsers --all      # все поддерживаемые, с подтверждением
```

Собираются из исходников локально, поэтому нужен C-компилятор. Скачанные `.so`
намеренно **не** коммитятся в репозиторий (`.gitignore`), так что после клона
подсветки нет, пока вы не выполните `--all` хотя бы раз.

## Настройка

Всё переопределяется в `lua/user/settings.lua` — он накладывается поверх
`lua/core/settings.lua` и имеет приоритет. Шаблон лежит в `lua/user_template/settings.lua`;
установщик копирует его в `lua/user/` при первом запуске.

```lua
-- lua/user/settings.lua
settings["colorscheme"] = "catppuccin"
settings["format_on_save"] = false
settings["treesitter_deps"] = { "lua", "go", "rust" }  -- сузить набор парсеров
```

Полный список настроек с комментариями — в начале `lua/core/settings.lua`.

## Команды

Всего 25 пользовательских команд. Самые нужные:

| Команда | Что делает |
| --- | --- |
| `:ConfigHealth` | проверка окружения: бинарники, LSP, тема, клавиши |
| `:Distro` | меню пакетов: каталог, установка, обновление, статус |
| `:DistroInstall <имя>` | поставить плагин из каталога (с подтверждением) |
| `:DistroCheck` | статус: что установлено, что не совпадает с lock-файлом |
| `:DistroParsers [--all]` | парсеры treesitter |
| `:DistroTools` | внешние утилиты: проверить, поставить (с подтверждением) |
| `:DistroBinaries` | бинарники: LSP, линтеры, форматтеры |
| `:DistroMirror` | корпоративный зеркали источников (внутренняя сеть) |
| `:DistroDiag` | диагностика: подключился ли LSP, куда уходят capability |
| `:DistroBench` | замер открытия на этой машине |
| `:DistroTrace` | дерево операций с таймингами |
| `:DistroClean` | удалить лишнее из кэша пакетов |
| `:Format` / `:FormatToggle` | форматировать / переключить format-on-save |
| `:FormatterToggleFt <lang>` | отключить формат для одного языка |
| `:WeakHwOn` / `:WeakHwOff` | пресет для слабого железа |
| `:TurboOn` / `:TurboOff` | отложить тяжёлое (полезно на больших проектах) |

## Хоткеи

`<leader>` — пробел. Полный список — в `lua/keymap/`, он разложен по файлам
`editor.lua`, `lang.lua`, `tool.lua`, `ui.lua`, `completion.lua`.

**Поиск и пикеры** (на `mini.pick`, без telescope):

| | |
| --- | --- |
| `<leader>ff` | файлы проекта |
| `<leader>fp` | живой поиск по проекту |
| `<leader>fb` / `<leader>fo` | буферы / недавние файлы |
| `<leader>fw` | символы по всему репозиторию |
| `<leader>fg` | git-ветки |
| `<C-p>` | панель команд |

**LSP:**

| | |
| --- | --- |
| `gd` / `gr` / `gi` / `gy` | определение / ссылки / реализации / тип |
| `K` / `gs` / `ga` | документация / подсказка аргументов / code action |
| `g[` / `g]` / `<leader>lx` | диагностика назад / вперёд / на строке |
| `<leader>rn` | переименование |
| `gw` | супертипы (интерфейсы, которые реализует тип) |

**Go:** `<leader>gt` тест функции · `<leader>ta` все тесты · `<leader>gf` альт-файл ·
`<leader>ar` разложить `x, err := f()` · `<leader>ie` обернуть в `if err != nil`.

**Файлы и буферы:** `<leader>e` проводник (netrw) у текущего файла ·
`<leader>E` у корня проекта · `<leader>sv`/`<leader>sh`/`<leader>sc` окна ·
`<leader>bn` новый буфер · `<A-q>` закрыть буфер.

**Git:** `[g`/`]g` по хункам · `<leader>gs` стейдж хунка · `<leader>gr` сбросить хунк ·
`<leader>gb` blame · `<leader>gd` diffview.

**Редактор:** `<C-s>` сохранить · `<C-q>` сохранить и выйти · `jj`/`jk` вставить `<Esc>`.

## Если что-то тормозит

Медленный старт или зависание обычно лечится одним из трёх:

1. `:DistroBench` — показывает, сколько стоит открытие, и сравнивает с чистым Neovim.
2. `:TurboOn` — откладывает тяжёлое (результат придёт позже, но первый кадр быстрее).
3. `:WeakHwOn` — пресет для слабого железа: выключает фоновые анализы gopls,
   линзы и прочие тяжёлые фоновые вещи.

## Структура

```
init.lua                 точка входа
lua/core/                ядро: настройки, режимы, инициализация
lua/distro/              пакетный менеджер: установка, lock, зеркала, трейс
lua/keymap/              хоткеи
lua/modules/             конфиги плагинов по группам
lua/user_template/       шаблон пользовательских настроек
pack/distro/start|opt/   вендоренные плагины
scripts/                 установщик и smoke-тест
docs/                    отчёты по разработке (см. ниже)
```

## Документация

- `docs/distro/` — контракты и отчёты по разработке: требования, архитектура,
  этапы реализации, ретроспективы. Это рабочие документы, а не руководство
  пользователя; читать их нужно, только если вы пишете код этого конфига.

## Проверка целостности

```sh
./scripts/smoke-test.sh     # ждёт: RESULT: PASS
```

Скрипт не ходит в сеть, ничего не устанавливает и не делает git-операций.

## Лицензия

См. [LICENSE](LICENSE).

## Благодарности

Собран на открытых проектах: [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter),
[mini.nvim](https://github.com/echasnovski/mini.nvim),
[nvim-cmp](https://github.com/hrsh7th/nvim-cmp),
[LuaSnip](https://github.com/L3MON4D3/LuaSnip),
[gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim),
[flash.nvim](https://github.com/stevearc/flash.nvim),
[diffview.nvim](https://github.com/sindrets/diffview.nvim),
[trouble.nvim](https://github.com/folke/trouble.nvim),
[plenary.nvim](https://github.com/nvim-lua/plenary.nvim),
[guihua.lua](https://github.com/lewis6991/guihua.lua),
[black-metal-theme-neovim](https://github.com/folke/black-metal-theme-neovim).
