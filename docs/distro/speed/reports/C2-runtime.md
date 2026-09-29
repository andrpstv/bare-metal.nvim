# C2 — рантайм-ядро: DONE

Дата: 2026-09-29. Smoke полный: **8/8 PASS**. PTY-сессии c2/c2b (Go-проект).

## C2a cmp (modules/configs/completion/cmp.lua)

- `preselect None→Item`: top-1 подсвечен сразу (конфиг активен — проверено
  `get_config().preselect=item`). Enter по-прежнему newline (маппинг CR),
  подтверждение на `<C-y>`, Tab ходит.
- Resolve-later: первая строка сниппета кэшируется по `snip_id` (сброс при >500).
  Раньше `get_id_snippet+get_docstring+3×gsub` бежали на каждый кандидат
  при каждом кейстроке.
- Buffer-источник от 3 символов (`keyword_length=3`).
- C2c-warm уже был в ветке (PickWarm в pick.lua + спаны definition/references
  в tracehooks) — не дублировал, только замерил (ниже).

## C2b recovery — главная находка цикла

Симптом: «cmp умирает на битых файлах до рестарта nvim».
Watchdog (`completion/lsp.lua`, `GoplsWatchdog`): LspDetach → проверка в
schedule → рестарт `:edit` с бэкоффом (макс 3) + глобальный `<leader>li`
с подсказкой без сервера. `<leader>lr` ставит suppress-флаг.

**Найден и убит самозацикл**: `:edit` на 0.12 сам шлёт LspDetach (доказано
стеком: detach шёл из `lsp.lua:165` через `vim.cmd("edit")`) — watchdog
перезапускал сам себя каждые 500мс бесконечно (7 нотифаев, счётчик вечно 1/3).
Лечение: suppress-флаг вокруг собственного `:edit` + пропуск modified-буфера
(E37) + задержка 1500мс (штатный переаттач после `:e!` успевает вернуться).

Проверка убийством клиента (`stop_client`): `clients=0` → `[gopls]` вернулся
за <5с, один нотифай, за 30с тишины повторов нет. Гейт C2b закрыт.

## C2d codelens

Фоновый refresh только на `BufWritePost` (был BufEnter/InsertLeave/BufWritePost —
запросы на каждый чих). `<leader>cl` на TestGreet: `LSP[gopls] all tests passed`,
без deprecation.

## Ключевое измерение: где реально душил cmp

Сервер в порядке (прямой `textDocument/completion` → 5 items, `gd` тёплый 3мс).
Автопуть молчал по двум причинам, обе доказаны:
1. **Харнесс-артефакт**: `tui-test type` шлёт текст bracketed-paste одним
   TextChangedI — upstream lp-гейт cmp (`col+1` строго) его скипает.
   Посимвольный ввод (`key press` по одной) даёт 4×FIRE:TextChanged и меню.
   Живой человек печатает посимвольно — путь работает (меню Print/Printf/Println
   + доки открылись). Заметка стенду: скорость печатать по одной клавише.
2. **Флап gopls** (выше): пока сервер detach/attach — запросы в пустоту.
   Теперь revive за секунды вместо рестарта nvim.

Остаток жалоб «нет методов после точки» — серверная латентность на больших
репо (debounce 150, индексация), не клиент: клиент теперь preselect + кэш.
Следующий шаг — C3 lean-матрица на большом репо.

## Цифры C2

- `:DistroBench`: open small ours 123мс (+102 к clean), big 123мс (+100) —
  на уровне базы (~138мс go), регрессии нет.
- `gd` тёплый: **3мс**, 1 результат.
- `gr`/definition sync-probe: 0 (фикстура мала, <8 символов) — честно, не баг.
- codelens deprecation: ноль в `:messages` за сессию.

## Гейт C2

smoke 8/8 · recovery доказан убийством · цикла рестартов нет · меню после
точки открывается · preselect активен. CLOSED.
