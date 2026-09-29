# C6 — срез лишнего: DAP-стек: DONE

Дата: 2026-09-29. Smoke полный: **8/8 PASS**. PTY c6: `:Distro` 22/0/0,
`:DapContinue` → чистый E492, `:ConfigHealth` 8 highlight-групп OK.

## Что убрано

**DAP-стек целиком** — 4 вендоренных плагина (~1.6МБ), конфиг 145 строк,
15 заглушек команд, записи lock/manifest, иконки, health-группы, autocmd:
- `pack/distro/opt/{nvim-dap,nvim-dap-go,nvim-dap-ui,nvim-nio}` (git rm)
- `lua/modules/configs/lang/dap.lua`, блок manifest, 4 ключа lock
- `dap`-таблица `icons.lua`, `DapBreakpoint/DapStopped` из health-чека,
  `dap-repl` autocmd, коммент `lang.lua`

Причина: ноль хоткеев, `dap_debug=false` в go.nvim, шапка `lang.lua` сама
писала «dap-плагины удалены» (врала — теперь правда). Дебаг — dlv в терминале,
как и было по факту. Восстановление из git одной командой (записано ниже).

## Счёт (сквозной с C5)

| Метрика | C5-старт | Сейчас | Delta цикла | Delta с baseline |
|---|---|---|---|---|
| строк `lua/` | 15613 | 15438 | **−175** | **−431 (−2.7%)** |
| вендор | ~47.6МБ | 46МБ | **−1.6МБ** | −1.6МБ |
| плагины / стабы | 26 / 15 DAP | 22 / 0 | −4 / −15 | — |
| старт empty/go/big | 77/167/151 | 78/169/149 | шум | ±шум |

Честно: миллисекунд не снято — стек грузился только по `:Dap*`, в boot-пути
его не было. Выигрыш: −1.6МБ клона, −175 строк поддержки, −15 призрачных команд,
`:Distro`/`Health`/`lock` консистентны (22/0/0).

## Что проверено и оставлено

- flash.nvim: ноль jump-маппингов, но char-режим (f/t) активен и меняет
  поведение — срез изменил бы моушены. Оставлен осознанно.
- nvim-lint, textobjects, trouble, diffview, luasnip+friendly-snippets,
  cmp-источники, guihua/plenary (deps): всё с живыми вызовами — остаются.
- Каталог (telescope/oil/toggleterm/which-key/todo/lualine/ibl/neogit/ntree):
  opt-in, ноль цены до установки — не трогал.
- Откат: `git checkout <base> -- pack/distro/opt/nvim-dap* lua/modules/configs/lang/dap.lua`
  + revert коммита (manifest/lock/config правки — тем же revert).
