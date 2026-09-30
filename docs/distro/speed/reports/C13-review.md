# Ревью 5 агентов: разбор и внедрение

Дата: 2026-09-30. Ветка `perf/tui-latency`. Все 5 агентов отработали
read-only, ничего не меняли. Ниже — триаж координатора: что внедрено,
что осознанно отложено/отклонено.

## Внедрено (код)

**Блокеры**
- B1 `keymap/completion.lua`: `ga` слал N×N codeAction-запросов (цикл по
  клиентам поверх веерного `buf_request`). Один вызов, `_client_id` из ctx,
  счётчик ответов сохранён (хендлер зовётся на клиента).
- K1 `keymap/init.lua`: `grx` добавлен в снос дефолтов — каждый `gr` ждал
  300мс timeoutlen. Одна строка, главный выигрыш ревью.
- F2 `distro/ui.lua`: `:DistroClean` считал известными только `plugins` —
  установленный из каталога telescope попадал в жертвы. Каталог добавлен.
- B2 `keymap/pick.lua`: replace-парсинг без версии (`=> ../local`) никогда
  не матчился — два шаблона вместо одного, проверено 4 формы.
- M5 `keymap/completion.lua`: `<leader>lr` на грязном буфере убивал LSP
  и падал с E37 — гард + pcall.

**Major**
- M1 `keymap/pick.lua`: снапшот поколения гонки (`race_seq`/`my_seq`/
  `race_alive`) — опоздавшие async-колбэки текста умирают молча.
- M2: удалён двойной `race_win()`.
- M3: одиночный LocationLink (`targetUri` без `uri`) больше не «no results».
- M4: `GOFLAGS` дописывается, а не затирается (`-tags` пользователя живы).
- M6: `ga` разделён на n/x, в visual — range выделения через
  `make_given_range_params` + кламп к содержимому (E-column от gopls).
- M7: `goto_file` возвращает bool, прыжки двигают курсор только при успехе.
- M9 `lsp.lua`: перепроверка клиента в defer + один notify вместо двух.
- F5 `distro/loader.lua`: `pack/finish/load` обёрнуты в xpcall-наконец —
  флаги и `load_depth` всегда возвращаются (было: одна ошибка = вечные
  cycle-заглушки). Побочно вскрыло и починило сломанный TierFolds
  (лишний `end`, раньше глотался молча — вот зачем нужен F7).
- F1 `distro/install.lua`: `needs.bins` проверяется ДО скачивания;
  shell-`build` выполняется в stage до переезда (старая версия цела);
  `:`-команды — через лоадер+pcall с честным сообщением; `treesitter` —
  указатель на `:DistroParsers`.
- F7 `distro/loader.lua`: несуществующий config и упавший setup/table-setup
  теперь ERROR-нотифай, а не тишина (+ `.vim` after/plugin унифицирован).
- F14: `adopt` — один `read`; `idle_timer` — добавлен `close()`.
  `M.Q`/`install_via_curl` оставлены (публичное API, копейки).
- F12 `distro/tools.lua`: `install_tool` резолвит и `binaries`
  (go→install_go, release→ad-hoc, system→hint) — `shfmt` больше не Unknown.
- F8 `distro/mirror_cmd.lua`: HEAD-probe только с confirm (URL показан);
  headless отказывается вместо молчаливого выхода.
- F9 `distro/install.lua`: `move_dir` с EXDEV-фолбэком (mv/Move-Item),
  чистка archive/stage на всех failure-ветках, точный текст ошибки.
- F11 `distro/lock.lua`: prune призраков при записи (кроме `bin/*`,
  `tools/*` — динамические).
- F13 `distro/install.lua`: код+хост в ошибках curl, путь лога,
  `extra_args` в API-вызовах.
- F10 `scripts/install.sh`: XDG_CONFIG_HOME, perl-зависимость и мёртвый
  perl-патч удалены, `lua/user/` не затирается при повторе.
- L6: `cmp_debounce/cmp_throttle` в settings + ось debounce в lean.
- K: desc для `jj/jk`/`ih`, `v→x` для J/K/</>/fs/gs/gr, `leader_help`
  индексирует v/x с суффиксом, NOTE для `gt`/`gi`/`<C-s>`, `grx` в снос.
- I1/I2: счётчик кэша статуслайна, hoisted menu-таблица cmp.
- Р19: внутренние `Turbo*` имена → `Perf*` (augroup/descs/префиксы трейса).

## Внедрено (доки)

- README: 27 команд + полные строки (Р1–Р3), 3-дефолт-LSP + hints (Р7–Р8),
  `li` только с LSP (Р9), шаблон с local/return + ручной клон (Р11–Р12),
  формат только LSP (Р14), telescope вместо mini.pick, unzip-строка (Р18).
- GUIDE: таблица команд дополнена, `fs` n/v, `cmp_defer_caps`→`perf_defer`,
  шаблон, парсеры только через команду (Р15), `gt`-тень.
- `11-speed-program.md`: пути `docs/distro/speed`, C5 и счёт команд.
- smoke-test.sh: 27 команд (добавлены 6×Perf, Р25).

## Осознанно НЕ тронуто

- F6 (порядок start-плагинов): проверено фактически — у темы нет `plugin/`,
  devicons используется через lazy pcall; поломок нет, риск правки выше пользы.
- F3-план/структура setup: consent/headless и dispatch по method починены;
  глубокий рефактор plan/run не требуется.
- `noremap=false` россыпью (кроме `v </>`): поведение не кусается сегодня;
  массовая замена — риск без выигрыша.
- `<leader>Q`-алиас, `timeoutlen` 300→200, `gc`-ноут: вкусовщина/риск,
  отложено.
- `M.Q`/`install_via_curl`: публичное API, оставлены.
- m9 TOCTOU-остаток: defer-перепроверка добавлена; идеального атомарного
  revive без гонок в архитектурe нет — принято.

## Гейты

- `luac -p` по всем тронутым lua, `bash -n` install.sh — чисто.
- smoke-test.sh: **8/8 PASS** (включая 27 команд).
- PTY: `gr` прыгает на использование, `VJ` двигает строку, visual `ga`
  открывает список (кламп убрал E-column), `:DistroSetup` headless
  отказывается чисто.
