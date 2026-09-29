# Baseline «было» — 2026-09-29, nvim 0.12.5, ветка refactor/simplify-and-harden

Стенд починен (коммит далее): `interactive-bench.sh` пишет `go.mod`
в корпус + валидный `package`-clause. До этого gopls сидел в degraded
single-file и Go-замеры упирались в таймаут (наблюдался stall 59с).

## smoke-test.sh --quick — PASS 7/7

`qa!` stderr пуст · guard 0.12.5≥0.11 · 9/9 модулей · 27 команд static+runtime ·
gopls attach 0 диагностик.

## startup-bench.sh (min-of-3)

| Открытие | clean | ours | delta |
|---|---|---|---|
| empty | 42мс | 76мс | +34мс |
| go file | 47мс | 165мс | +118мс |
| big file | 48мс | 143мс | +95мс |

## Опорные цифры из аудитов (рантайм)

- Холодный старт медиана ~53мс (ours) / ~17мс (clean).
- Открытие go 2503 строк ~138мс / clean ~24мс; сверх пустого старта ~86мс:
  nvim-cmp ~15мс, luasnip+friendly-snippets ~13мс, gitsigns ~9мс, BufRead-агрегаты ~19мс.
- `ts_parse` go5k 22.7мс, `lsp_attach` ~55мс (с `go.mod`), `lsp_diag` упирался
  в 15с-таймаут без `go.mod` — артефакт стенда, не конфига.
- cmp popup после `.`: не измерен, субъективно «надо печатать» —
  первые цифры даст C2-стенд (tui-test + interactive-bench с go.mod).
- `gd/gr` RTT: не измерен — первые цифры в C2 (`:DistroBench`, trace-спаны).

## Что дальше

Цикл 1 — P0 из `../11-speed-program.md` §4. Гейт: smoke 8/8 полный,
ноль E492 в PTY-матрице хоткеев.
