# Changelog — bare-metal.nvim

## v4.4.1 — leader help on delay (2026-10-01)

Кастомная which-key-подсказка больше не мигает на каждое нажатие лидера:
`<leader>` лишь взводит показ, всплытие через `leader_help_delay_ms`
(по умолч. 3000мс, аналог which-key `delay`, от `timeoutlen` не зависит),
любая следующая клавиша гасит. Билтин, без зависимостей, fast-event-safe
наблюдатель пережил жёсткий мэш-клавиш без единой ошибки (проверено в PTY).

## v4.4.0 — perf/tui-latency → main (2026-10-01)

Скоростной цикл C0–C14 + подготовка к релизу: онбординг первого запуска,
честные обещания, kill-switch плагинов, релизный гейт. Smoke 8/8,
`scripts/release-check.sh` (privacy gate + smoke) — зелёный.

### Скорость (замеры — `docs/distro/speed/reports/C*.md`)

- gd туда-обратно по внешним пакетам: медленные секунды → 27–230мс туда
  (qualified-пути, TTL-кэш `go list`, pure-Lua резолв vendor/GOROOT/modcache,
  гонка LSP-vs-текст, `:b` вместо `:edit`, метка `m'`).
- Ctrl-O назад: 60–99мс + 25МБ мусора на свитч → 0мс. Корень — foldexpr
  пина nvim-treesitter 09-2024 (пересчёт query на строку: 181 строка — 60мс,
  1104 строки — до 3с). Замена на встроенный `vim.treesitter.foldexpr()`,
  TierFolds чинит отравленные окна через BufWinEnter (C14).
- Coalesce organizeImports: быстрые сейвы больше не ставят gopls в очередь.
- cmp: preselect-Item, snippet-кэш, `C-y` вместо Enter осознанно.
- Codelens только на сейв; gopls-watchdog без self-loop.

### Онбординг (было: монохром + тишина → стало: подсказки)

- `:DistroSetup` — всё недостающее (парсеры + бинарники + gopls) за один confirm.
- Пустой `nvim` без парсеров: стартер-хинт (сам гаснет, уважает отказ).
- Первый Go-файл без gopls: нudge раз за сессию + хинт-карты gd/gr/K
  вместо молчаливого builtin-мусора. `gopls_found()` смотрит и в `~/go/bin`
  (go.nvim дописывает GOPATH/bin в PATH лениво).
- `:Tutor` (был undiscoverable), day-1 вставки в тутор: Ctrl-O, `C-y`,
  `gt` vs `<leader>gt`, режимы `<leader>fs`.

### Go-повседневность

- `<leader>rr` / `<leader>rb` — `:GoRun` / `:GoBuild` (были только тесты).
- DAP: честно в GUIDE — UI брейкпоинтов нет, отладка через `dlv` в терминале.
- Тутор: `<leader>tt` → `<leader>gt`.

### Кастомизация без форка

- `settings.disabled_plugins` wired в лоадер (eager + lazy + cmd-стабы).
- `user.keymap.*` проверен сквозно; шаблоны с контрактом формата;
  мёртвый пример с Lspsaga убран.
- GUIDE: секции «Свои кеймапы», kill-switch, `user.configs/<name> → false`.

### Гигиена

- `nvim-treesitter` на HEAD грузится (аудит-утверждение «не грузится»
  перепроверено и опровергнуто: configs/textobjects/highlighter/go-parser — ok).
- `telescope.nvim` лениво грузится из вендора: `ff/fp` из коробки.
- Локальные stale-ветки удалены (`minimal-config`,
  `refactor/simplify-and-harden` — полностью вмержены).
- `distro-lock.json.bak` удалён; `lazy-lock.json` оставлен осознанно
  (legacy, внешний flake-риск — см. `docs/distro/README`).
- Архитектурный док: 21 плагин + 9 каталога, путь парсеров, решение
  «pack/ вендорится как есть» зафиксировано.

## v4.3.0 и ранее

См. `git log main` и `docs/distro/archive-2026-09/28-release-decision.md`
(решение по релизу RELEASE-1, 2026-09-27).
