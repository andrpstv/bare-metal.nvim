# C5 — минимализация: DONE

Дата: 2026-09-29. Smoke полный: **8/8 PASS** (7/7 модулей, 21 команда).
PTY: статуслайн Go-буфера ок, `:PerfDeferStatus/:PerfLeanStatus` работают,
`:TurboOn` → честный E492 (команда удалена).

## Счёт

| Метрика | Было | Стало | Delta |
|---|---|---|---|
| строк в `lua/` | 15869 | 15613 | **−256 (−1.6%)** |
| diff коммита | — | +53 / −307 | net −254 |
| старт empty (min-of-3) | 76мс | 77мс | шум (±1) |
| старт go-file | 173мс | 167мс | −6мс (шум/погрешность) |
| старт big-file | 153мс | 151мс | −2мс (шум) |
| smoke | 8/8 | 8/8 | гейт держится |

Честно: прироста старта почти нет — шимы были ленивыми и дешёвыми на boot.
Выигрыш — поддерживаемость: −2 модуля, −9 команд-дублей, один путь вместо двух.

## Что вырезано (и почему безопасно)

1. **`core/turbo.lua` + `core/weak_hw.lua` (−177)**: DEPRECATED-шимы поверх
   `core/perf`. Env-совместимость (`NVIM_TURBO`, `NVIM_TURBO_MODE`,
   `NVIM_WEAK_HW`) живёт в самом `perf.lua` (6 строк) и сохранена полностью —
   убраны только 6 имён команд (`:Turbo*`, `:WeakHw*` → есть `:PerfDefer*`,
   `:PerfLean*`). Ключи settings (`weak_hw`, `gopls_weak_hw`, …) продолжают
   маппиться в lean как раньше.
2. **Мёртвые `modules/utils` (−~50)**: `hl_to_rgb`, `extend_hl`,
   `gen_cursorword_hl`, `tobool` — ноль вызовов во всём репо (проверено grep).
3. **Дубли хоткеев `pc/pp/pr`** (были копиями `ps/pl/pu`, нигде не
   задокументированы): группа `p` в LeaderHelp почищена.
4. **Двойной путь в статуслайне** (`core.turbo` vs `core.perf` + 7-полевой
   ключ): теперь только `perf.defer_on()`, ключ из 3 полей.
5. **Протухшие descs/комменты** (`alias of :TurboOn` и т.п. в perf/loader/
   theme/gopls/diag): каноника — perf, история не врёт.
6. **Шаблон и доки**: `user_template` `catppuccin` → `khold` (catppuccin не
   вендорен — дефолт был битым); README «25 команд» → 21 (факт smoke),
   Turbo/WeakHw строки → Perf; гайд — те же замены.
7. **`distro/diag`**: `turbo`-секция отчёта → `defer` из `perf` напрямую
   (старый код требовал удалённый модуль).

## Что осознанно НЕ тронуто

- Forensics (~5000 строк: trace/diag/bench/ui): фичи `:Distro*`, lazy,
  ноль цены на старте. Резать = лишать клиентов инструментов.
- `go_assign` (296): сложный, но уникальный (GoLand Alt+Enter), с тестами
  через smoke-путь. Причина есть — живёт.
- `signature` (316): липкий флоат с treesitter-снапом, builtin так не умеет.
- Legacy settings-ключи и env-алиасы: 10 строк совместимости, модулей нет.
- `lazy-lock.json`, perf-deprecated слой в settings: следующим заходом (C4).
- Чужие файлы не трогал: `distro/tracehooks.lua` (M, параллельная работа),
  `scripts/tui-latency-bench.lua` + `docs/distro/33-*` (untracked, чужие).

## Миграция для потребителей

`:TurboOn/Off/Status` → `:PerfDeferOn/Off/Status`;
`:WeakHwOn/Off/Status` → `:PerfLeanOn/Off/Status`.
Env-переменные и settings-ключи работают как раньше. `<leader>pc/pp/pr` убраны
(остались `ps/pl/pu`).
