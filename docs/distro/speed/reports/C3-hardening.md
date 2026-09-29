# C3 — слабые ПК и неубиваемость: DONE

Дата: 2026-09-29. Smoke полный: **8/8 PASS**. Сессии c3a–c3h (tui-test PTY).
Фикстура: /tmp/qa-big (10 файлов ×~488 строк, go.mod), /tmp/qa-empty (solo.go).

## C3a lean-матрица (full vs NVIM_PERF_LEAN=1)

| Проверка | full | lean |
|---|---|---|
| attach + 38 диагностик | da | da (`lean=true`) |
| gd RTT (definition, тёплый) | 2мс | 1мс |
| меню после `s.` (методы/поля/сниппеты/доки) | da | da |
| G/gg скролл 488 строк | мгновенно | мгновенно |

Фризов не observed. Деградация lean = качество (lite-хайлайт, debounce 250),
фичи на месте. Гейт пройден.

## C3b recovery-матрица

- **Битый синтаксис + битый go.mod**: gopls attached, диагностика показана,
  UI живо, меню открывается (buffer-источник: `Println [BUF]` на `prin`).
  Шум: `InlayHint: no package metadata` повторяется — серверный спам,
  бэклог (глушить централизованно, не в этом цикле).
- **Нет бинарников в PATH** (только nvim+python3): старт чистый,
  `[lsp] binary for [gopls] not found, skipping`, глобальный `<leader>li`
  говорит дословно что ставить (`go install …`, `:DistroBinaries`).
- **Убийство gopls** (C2, подтверждено снова): revive <5с, один нотифай, без цикла.

## C3c Go-сессия

- `:DistroTrace on` + `gd`: спаны `lsp:definition dispatch`,
  `keypress_to_request 0.75мс`, `request_to_response` — трейсинг хопов работает.
- **Найден и починен detach-шторм навигации**: прыжок в ТОТ ЖЕ файл шёл через
  `vim.cmd.edit` → LspDetach на 0.12 → ложный варнинг watchdog на каждый gd
  (доказано стеком: detach из `pick.lua:494 handler`).
  Фикс: тот же буфер — только `set_cursor` без `:edit`; плюс `m'` для `<C-o>`.
- stdlib: `gd` на `Errorf` → `GOROOT/fmt/errors.go:23`, статуслайн `[-]`,
  jumplist хранит возврат (`:jumps` полон store0.go), detach ноль.
- `gr` → references-пикер, `gO` → 160 document symbols.
- cgo-файл: attach + 4 диагностики, без падений. Без go.mod: single-file,
  меню после `fmt.` открывается.
- Заметка фикстуры: генератор даёт DuplicateDecl между файлами (один пакет) —
  на тесты не влияет, gopls резолвит внутри файла.

## Изменения цикла

`lua/keymap/pick.lua` (same-buffer jump без `:edit` + `m'`). Остальное C3 —
чистая верификация, кода не требовала.

## Гейт C3

lean/full паритет · recovery во всех осях · Go-сессия без FAIL ·
smoke 8/8. CLOSED. Остался C4 (доки=факт, установщик, тег).
