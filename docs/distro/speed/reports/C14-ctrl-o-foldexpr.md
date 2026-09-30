# C14 — Ctrl-O назад из внешнего пакета: foldexpr плагина жег 60мс+25МБ на свитч

Дата: 2026-09-30. Ветка: `perf/tui-latency` @ `4f54ec7`.

## Симптом
`gd` на `mongo.Client` из `tailscale/cmd/tailscaled/proxy.go` — ок, а `Ctrl-O`
назад «грузит долго». Замер in-process (`:b` туда-обратно, `vim.uv.hrtime`):
вход в `proxy.go` (181 строка, 5КБ) — **60–99мс**, вход в `client.go`
(1104 строки, 37КБ, modcache) — **0мс**.

## Трейл (что проверено и отброшено)
- gitsigns/diagnostics в свитче не участвуют (пустой фрейм, 0.00–0.01мс).
- `eventignore=all` (без автокоманд вообще): всё равно ~91мс — не автокоманды.
- `vim.treesitter.stop()` на обоих буферах: ~89мс — не подсветка.
- `set foldmethod=manual` через `vim.o`: всё равно 84мс — **тест был инвалиден**:
  `vim.o` меняет глобал, а опция window-local, окно осталось на expr.
- GC-гипотеза с `collectgarbage("stop")` дала ключ: вход в proxy.go
  аллоцирует **~25МБ за свитч** (7396КБ → 82МБ за 8 свитчей), вход в
  client.go — ~15КБ. Мусор → паузы GC → «прерывистые» 77–90мс.
- Решающий тест: `setlocal foldmethod=manual` на proxy.go → **0мс, +15КБ**.
  До: `foldmethod=expr foldexpr=nvim_treesitter#foldexpr()`.

## Корень
Старый `nvim-treesitter` (пин 09-2024) `fold.lua` на 0.12 пере-считывает
query на каждую строку при каждом входе в окно: 181 строка — 60мс+25МБ,
1104 строки — до 3с (поэтому либы раньше уехали на manual в C9, а свои файлы
остались на expr и тихо жгли). `:b`/C-O не шлёт BufReadPost — окно залипало
на expr (TierFolds чинил только BufReadPost/FileType до этого тикета).

## Фикс (`4f54ec7`)
- Глобальный foldexpr по умолчанию: `v:lua.vim.treesitter.foldexpr()`
  (встроенный, рантайм 0.10+; E121 невозможен по построению). Замер:
  **0мс** на proxy.go и на client.go (1104 строки), память плоская.
- TierFolds: full-tier свои файлы → window-local expr+builtin (чинит окна,
  отравленные старым значением, на FileType/BufReadPost/**BufWinEnter**);
  off-tier и go-либы → manual как раньше.
- Плагинный fold-модуль в setup у нас никогда не включался — отсылка была
  только в этих двух местах, борьба за опцию исключена.
- Попутно в коммите: `lsp:definition/references` dispatch-спаны в tracehooks,
  отчёт 33-config-overload-audit, `scripts/tui-latency-bench.lua`.

## Валидация (свежая сессия, новый конфиг, настоящие keystrokes)
- `gd` (холодный gopls после рестарта): 310мс wall → `client.go`.
- `Ctrl-O`: 147мс wall (включая ≤100мс гранулярности PTY-поллинга).
- In-process ×4: `client=0мс proxy=0мс`, 6644→6924КБ за 8 свитчей (~35КБ/свитч
  норма). Smoke 8/8. Запушено.
