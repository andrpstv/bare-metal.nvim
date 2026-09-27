# 23 — Приёмка релиза (рецензент, read-only)

Дата: 2026-09-27. Рецензент: 🔍 Reviewer. Правок в конфиг не вносил, коммитов не делал.
HEAD на момент приёмки: `896f09a` («chore: drop nixos/, flake and upstream CI — not a fork»).

**ВЕРДИКТ: НЕЛЬЗЯ.** Релиз нельзя отдавать потребителю. Причина не в том, что сломалось
(регрессий нет), а в том, что **не сделано 5 из 6 пунктов задания**, а два оставшихся P0
из `docs/distro/22` не закрыты и по-прежнему ломают первый запуск потребителя.

---

## 0. Инструмент: `tui-test` работает

Проверено исполнением, не на глаз.

```
$ tui-test --version
tui-test 0.1.0-beta.4            # /opt/homebrew/bin/tui-test
$ tui-test run --cols 120 --rows 34 nvim -u NONE -i NONE --noplugin /tmp/ttcheck/hello.txt
$ tui-test screenshot -o proof.png   → 42911 bytes, 120x34
```

Скриншот `proof/00-tui-test-works.png`: настоящее окно Neovim, три строки текста,
статусная строка `hello.txt … 1,1 … All`. Реальные пиксели из PTY, не симуляция.

Две особенности инструмента, о которых стоит знать (не дефекты конфига):

1. `tui-test key press colon` **не срабатывает** — `:` не доходит до Neovim, текст
   команды уходит в буфер как обычный ввод. Для Ex-команд работает только
   `tui-test write ':DistroTrace\n'`. Проверено: первый заход дал в файле
   `nDistroTrace` как текст (строка 2), второй через `write` — корректно.
2. Первый запуск на несуществующем файле даёт пустой экран (`~` везде). Файл надо
   создать **до** старта nvim, иначе снимок вводит в заблуждение так же, как глаза.

---

## 1. Онбординг, P0 из аудита `docs/distro/22`

### P0-1 (парсеры): НЕ ЗАКРЫТ

Аудит `docs/distro/22-consumer-capabilities.md:464` заявлял: парсеров нет, автобустрапа нет,
первый запуск = нет подсветки. **На текущем коде это по-прежнему верно.**

| Проверка | Команда | Результат |
|---|---|---|
| парсеры в репозитории | `ls pack/distro/parser/` | только `.gitkeep` |
| `.so` в репозитории | `find pack/distro/parser -name '*.so' \| wc -l` | **0** |
| парсеры вне репозитория | `ls ~/.local/share/nvim/site/parser/*.so \| wc -l` | **46** |
| автобустрап | `grep -rn "autobootstrap\|auto_install\|ensure_parsers" lua/` | **пусто** |
| `*.so` в `.gitignore` | `.gitignore:12` | `pack/distro/parser/*.so` — да |
| отслеживается ли `.so` в git | `git ls-files \| grep -c '\.so$'` | 3 (это LuaSnip/jsregexp, не парсеры) |

Механика ровно та, что описана в аудите: 46 рабочих парсеров лежат в
`~/.local/share/nvim/site/parser` **вне репозитория**, в репозитории — ноль, автобустрапа
нет. У потребителя, который ставит этот конфиг на чистую машину, `ensure_installed`
(`lua/modules/configs/editor/treesitter.lua:27`) отработает, но каталог назначения
внутри репозитория пуст и заполняется только в обход сети, которую политик запрещает
трогать без согласия.

**Это блокер №1.** Первый запуск потребителя = нет подсветки синтаксиса.

Уточнение к цифре «46»: это 46 `.so` в пользовательском каталоге, а
`settings["treesitter_deps"]` (`lua/core/settings.lua:299-320`) перечисляет **20**
языков. На диске в `pack/distro/opt/nvim-treesitter/parser/` — 21 `.so`, и все 20
конфигурируемых языков там присутствуют, и они под `.gitignore`. То есть на
**этой** машине подсветка работает. Сломана именно переносимость на чистый клон —
это важное различие, и его нельзя подменять фразой «парсеры есть».

### P0-2 (документация): НЕ ЗАКРЫТ

- `CONSUMER-GUIDE.md` — **не существует** (`ls` → No such file or directory). В задании
  он был заявлен как обязательный. Это блокер №2.
- `README.md` — **не тронут коммитом** (`git show --stat 896f09a | grep -i readme` → пусто).
  Это по-прежнему README чужого проекта `ayamir/nvimdots`: бейджи релизов ведут на
  `github.com/ayamir/nvimdots/releases`, дискорд — на `discord.gg/rE46YdFAUc`, deepwiki —
  на `deepwiki.com/ayamir/nvimdots`, звёзды считаются у `ayamir/nvimdots`. Человек,
  пришедший по README, попадает в чужой репозиторий. Блокер №3.
- Обещания «свой README», «CONSUMER-GUIDE.md», «команда поставить всё» в коммите
  `896f09a` **нет** — он только про nixos/flake/CI.

### P0-3 (Windows): НЕ ЗАКРЫТ

См. раздел 3. Дефект реальный и подтверждён в коде.

### Упоминания nixos/flake в своём коде: ЧИСТО

```
$ git grep -l -iE "nixos|flake\.nix" -- . ':!pack/distro/opt'
README.md
docs/opt-2026-09-25.md
docs/review-2026-09-25.md
pack/distro/start/nvim-web-devicons/lua/nvim-web-devicons/default/icons_by_operating_system.lua
```

- `nixos/`, `flake.nix`, `flake.lock`, `.github/` — **удалены** (проверено `ls -d` → No such file).
- В `lua/`, `init.lua`, `scripts/` упоминаний не осталось — это правда.
- `pack/distro/opt/**` (LuaSnip, nvim-lspconfig, nvim-lint) и `pack/distro/start/**`
  (devicons) — это вендоренные чужие плагины, их `flake.lock`/`nixd.lua` редактировать
  нельзя. Зачёт корректный, претензии здесь быть не может.
- `README.md` и два моих же review-документа — упоминания исторические, не зависимости.

### which-key: НЕ РАБОТАЕТ ВИДИМО

Требование: «187 хоткеев должны быть видимы». Фактически:

```
$ grep -rn "require(\"which-key\")\|which_key.setup\|wk.setup" lua/   → пусто
$ grep -rhoE '\bmap\(' lua/ | wc -l                                    → 180
$ ls pack/distro/opt/nvim-web-devicons/... (leader)                    → 78 уникальных <leader>*
```

`which-key.nvim` есть в манифесте (`lua/distro/manifest.lua:103`) и грузится
(`lua/modules/configs/tool/whichkey.lua:2`), но **`setup()` не вызывается нигде**.
Плагин без `setup()` не строит popup.

Доказательство в UI: `proof/02-leader-whichkey.png` — нажат `<Space>` (leader = space,
`lua/core/init.lua:25`), на экране **никакого всплывающего окна нет**. Подсказки leader
потребитель не увидит.

Плюс расхождение чисел: в задании 187 хоткеев, в коде 180 вызовов `map(`. Мелкое, но
задание и код не сходятся — стоит свести.

---

## 2. Регрессии: ЗЕЛЁНЫЕ

Проверено **после** коммита `896f09a`.

```
$ nvim --headless -c 'qa!' ; echo $?     → 0
$ ./scripts/smoke-test.sh
summary: 8 passed, 0 failed, 0 skipped
PASS … all 25 commands declared in source
PASS runtime: exists(':Cmd')==2 for all commands
RESULT: PASS
startup ours=73ms clean=39ms ratio=1x (limit 5x, median of 5)
```

Ничего из ранее починенного не сломано. Все восемь пунктов проходят, 25 команд
объявлены и вызываются, старт в пределах нормы.

**Замечание о моей собственной методике** (записано, чтобы не повторить):
первый замер вернул `rc=127`. Это был артефакт обёртки (`timeout` на macOS нет,
nvim не запускался вовсе), а не падение конфига. После снятия обёртки — `rc=0`.
Число, полученное не тем инструментом, которым думали, я в отчёт не пускаю.

### Политика «никаких сетевых обращений без согласия»: НЕ СЛОМАНА

Это отдельная проверка, потому что автобустрап мог бы её легко порушить.

```
$ grep -rn "require_consent" lua/distro/install.lua
41: function M.require_consent(opts)
43:   if opts.user_confirmed ~= true then
44:     error("Refusing: this needs explicit confirmation. …")
50:     error("Refusing: this needs explicit confirmation. Re-run with --yes. …")
356: M.require_consent(opts)
```

`lua/distro/install.lua:1-2` — «Hard rule: no call below touches network unless
opts.user_confirmed == true». Гард стоит до скачивания (`install.lua:356`). Файл
`lua/distro/install.lua:1` — единственное место, где живут curl/tar. Политика держится.
**НЕ ТРОГАТЬ при добавлении автобустрапа** — это прямое требование владельца.

---

## 3. Windows: НЕ ИЗМЕРЕНО (проверено чтением кода)

Измерять нельзя — macOS arm64. Ниже только то, что сломается, с указанием места.

| Что | Где | Что сломается |
|---|---|---|
| **Сборка парсеров `cl` с gcc-флагами** | `lua/distro/treesitter.lua:62-71` | `cc()` возвращает `cl` как последний вариант, комментарий в коде сам признаёт: `-- MSVC (Windows): flags below are gcc-style, may need tuning per setup`. Флаги вида `-fPIC -shared` MSVC не понимает. **Нет подсветки = нет продукта** (это и был P0-3 аудита). |
| **Путь к lazygit** | `lua/core/git_colors.lua:60` | `vim.fn.expand("$APPDATA") .. "/lazygit"` — прямой склей с `/`. На Windows `APPDATA` = `C:\Users\...\AppData\Roaming`, итог `...\Roaming/lazygit`. Смешанные разделители обычно терпимы, но код не заявлен как проверенный. |
| **`%LOCALAPPDATA%`** | `lua/distro/diag.lua:83-91` | Обработан аккуратно: при unset пишет `NOT MEASURED`, а не врёт. Это правильное поведение, дефекта нет. |
| **`findstr` / `grepprg`** | `lua/core/options.lua:140-156` | Используется платформенный дефолт Neovim + фолбэк. Гард `executable("rg")`. Выглядит корректно по чтению. |
| **`executable()` для тулчейна** | `lua/distro/tools.lua:13-14`, `lua/core/health.lua:167` | Для gcc на Windows предлагается w64devkit/WinLibs. `health.lua:167` уже проверяет `cc/gcc/cl/clang`. Адекватно. |
| **clipboard** | `lua/core/init.lua:51-121` | Разделены по платформам: pbcopy, win32yank.exe, wl-copy, xclip, xsel. Выглядит корректно. |
| **shell** | `lua/core/init.lua:121,139` | `pwsh`, иначе `powershell`, с гардом `executable`. Корректно. |

**Итог: НЕ ИЗМЕРЕНО.** Один блокер, который сломается железно, — `cl` с gcc-флагами
(`treesitter.lua:69-70`, признано в коде). Остальное — чтением кода дефектов не видно,
но чтение не заменяет прогон. Помечено как «НЕ ИЗМЕРЕНО», а не как «в порядке».

---

## 4. Честность замераний: ЗАМЕЧАНИЙ НЕТ (по новому коммиту)

Проверял именно то, о чём владелец предупредил: недоказанные числа, поданные как измеренные.

Коммит `896f09a` — числами не напичкан, а **явно отделяет измеренное от неизмеренного**:

- «Verified: `nvim --headless -c 'qa!'` exits 0; `./scripts/smoke-test.sh` RESULT: PASS
  (8 passed, 0 failed) after the change.» — я это **перепроверил независимо**, совпало.
- «Not measured: NixOS users lose the module path. Nothing in this repo used it, but the
  packaging was the only NixOS entry point, so removing it is a real change for anyone
  who relied on `<nixpkgs>`… flagged here rather than silently dropped.» — ровно та
  осторожность, которой не хватало в старых замерах. Это плюс.
- Утверждения проверяемы и проверяемы мной: «nothing in the product reads any of it»
  — подтвердилось (`git grep` по `lua/ init.lua scripts/` чист).

Предыдущие коммиты (`f1ddefc` и далее) в этом смысле образцовые: в теле `f1ddefc`
прямо написано «The 21.5 vs 2.0 split is the proof: the old 22.0ms "response" was…» —
то есть автор показывает расклад, а не итог. Претензий к честности замеров **нет**.

Отдельно напоминаю владельцу про старый график измерений, который уже однажды дорого
стоил (из моей памяти проекта): **шум на этой машине — медиана парного |A−B| ≈ 4.14 мс**,
медианная дельта ≈ 1.28 мс. Число меньше 4 мс, поданное как «выигрыш», разрешающей
способности не имеет. В новом коммите таких чисел нет — риск не реализовался.

---

## 5. Незакрытое: инструмент диагностики по-прежнему вводит в заблуждение

Тест-потребитель заявил: дерево показывает 26 мс там, где человек ждёт 8 секунд, и
`gr`/пикер в трейс не попадают вообще. **Первое — подтвердилось, второе — подтвердилось
частично. Это НЕ документированное ограничение, это дефект инструмента.**

### 5a. `gr`/пикер в трейс не попадают — ПОДТВЕРЖДЕНО КОДОМ

```
$ grep -n "t\.span\|trace\.log\|M\.sub" lua/keymap/pick.lua
34:   local res = t.span("picker:ensure", _pick_ensure_inner)
67:   return t.span("picker:mini.pick", function()
95:   return t.span("picker:mini.extra", function()
```

Три точки трассировки есть. Но `gr` — это **не** они:

- `gr` определён в `lua/keymap/completion.lua:95-97` как `_pick_lsp("references")`.
- `_G._pick_lsp` (`lua/keymap/pick.lua:127`) — тело **не содержит ни одного**
  `t.span` / `trace.log` / `M.sub` (проверено построчно по диапазону 127-300).

Итог: обёрнуты `_pick` (mini.pick), `_pick_extra` (mini.extra) и `_pick_ensure`.
**`_pick_lsp` — то есть `gr`, `gd`, `gi` — не обёрнут.** Самый частый путь потребителя
(«нажал `gd`, ждал 8 секунд») в трейс не попадает **вообще**. Именно это и заявил
тест-потребитель, и это правда.

### 5b. Дерево показывает не то, что человек чувствует — ПОДТВЕРЖДЕНО

Собственный коммит `a0f8de3` описывает ровно эту болезнь и лечит верхушку:

> «"gd = 4.24 ms" was the cost of SENDING the request; the action really took 343.5 ms.»

Но лечение — только для верхнего узла. В теле того же коммита остаётся:

```
▸ pick_lsp/definition   28.03 ms  TOTAL (requests: 1)
  ├─ · pick_lsp/definition/keypress_to_request     24.88 ms
  ├─ · pick_lsp/definition/request_to_response      0.96 ms
  └─ · pick_lsp/definition/response_to_cursor      2.19 ms
```

`request_to_response` = **0.96 мс** — это не «человек ждал ответ сервера», это время
передачи уже готового ответа. Реальные 8 секунд ожидания gopls живут **вне** измеренного
отрезка: запрос ушёл, дерево закрылось, а ответ пришёл через 8 секунд уже без него.
Плюс `a0f8de3` сам пишет, что `_pick_lsp` не трейсится — то есть верхнего узла с
«полным временем действия» для `gr`/`gd` **не существует вовсе**.

**Это не «документированное ограничение».** Ограничение можно объявить словами; здесь
инструмент показывает число (0.96 мс) напротив того, что человек пережил (8 с), и
нигде не говорит, что это несопоставимые вещи. Для потребителя, который пришёл
разобраться «почему тормозит», это actively misleading.

### 5c. Побочно: дерево на холоде пустое

`proof/03-distrotrace.png` — `:DistroTrace` на холодном старте не показывает ничего.
Причина не дефект, а дизайн: `lua/distro/trace.lua:39` — `M.enabled = false`, трейс
выключен по умолчанию и включается только через `:DistroTrace`/`trace.enable`. Но это
стоит сказать в документации, иначе первый потребитель решит, что инструмент сломан.

---

## Блокеры по приоритету

| # | Блокер | Место | Почему блокер |
|---|---|---|---|
| 1 | Нет автобустрапа парсеров: 46 `.so` вне репозитория, в репо 0 | `pack/distro/parser/`, `lua/modules/configs/editor/treesitter.lua:27` | Чистый клон = нет подсветки. P0-1 не закрыт. |
| 2 | `CONSUMER-GUIDE.md` не существует | — | Обязательный артефакт задания отсутствует. |
| 3 | `README.md` — чужой проект `ayamir/nvimdots`, коммитом не тронут | `README.md:2`, `:9`, `:14` | Человек по README уходит в чужой репозиторий. P0-2 не закрыт. |
| 4 | `which-key` грузится, но `setup()` не вызывается → подсказки leader нет | `lua/modules/configs/tool/whichkey.lua:2` | Проверено в UI: popup не появляется. |
| 5 | Windows: `cl` собирается с gcc-флагами | `lua/distro/treesitter.lua:69-70` | Признано в коде. Нет подсветки = нет продукта. **НЕ ИЗМЕРЕНО.** |
| 6 | `_pick_lsp` (`gr`/`gd`/`gi`) не трейсится; `request_to_response` 0.96 мс против 8 с ожидания | `lua/keymap/pick.lua:127`, коммит `a0f8de3` | Диагностика вводит в заблуждение. Не «ограничение». |

## Что в порядке

- `tui-test` v0.1.0-beta.4 работает, даёт реальные пиксели из PTY. Инструмент годен.
- Регрессий нет: `rc=0`, smoke-test 8/8 PASS, 25 команд на месте, старт 73/39 мс.
- Ничего из ранее починенного не сломано (6c70f62, a0f8de3, 5dba962, 4ae7f15, ffdd0d8, 19b567a, 3955abb, 864a8e8).
- `nixos/`, `flake.nix`, `flake.lock`, `.github/` удалены; в своём коде упоминаний не осталось.
- Политика «нет сети без согласия» цела: `install.lua:41-50, 356`.
- Новая документация честная: «Verified» перепроверяемо и совпало, «Not measured» помечено явно.
- Диагностика `LOCALAPPDATA` не врёт при unset (`diag.lua:89`).

## Границы приёмки

Проверено: регрессии, команды, сетевая политика, удаление наследия, состав хоткеев,
наличие/отсутствие артефактов, поведение UI для Go-файла, leader, `:DistroTrace`.
**НЕ ИЗМЕРЕНО:** Windows целиком (нет платформы), реальный первый запуск на чистой машине
(парсеры на этой машине есть, поэтому сценарий «пустой клон» воспроизведён только по
коду и диску, а не установкой с нуля), «медленный HDD/Defender» сценарий.
Скриншоты: `proof/00-tui-test-works.png`, `01-go-no-parsers.png`, `02-leader-whichkey.png`,
`03-distrotrace.png`.

Оговорка к `01-go-no-parsers.png`: строки `initialization failed: … go: go.mod file not found`
на снимке — **артефакт моего теста** (я положил `main.go` в `/tmp` без `go.mod`), а не
дефект конфига. Подсветка на снимке есть, что согласуется с 21 установленным парсером.
Репортёром это отмечено, чтобы вывод не был прочитан неверно.
