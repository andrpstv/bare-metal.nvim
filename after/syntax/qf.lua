-- Подсветка формата core.qf (`путь │ строка:кол ✗ текст`): стоковый syntax/qf.vim ждёт `|`.
-- Строки без файла (заголовки, итоги) остаются обычным текстом.
vim.cmd([[
syntax clear
syntax match qfPath /^.\{-}\ze │ / nextgroup=qfSep
syntax match qfSep / │ / contained nextgroup=qfPos
syntax match qfPos /\d\+\%(:\d\+\)\?/ contained nextgroup=qfError,qfWarn,qfInfo,qfHint skipwhite
syntax match qfError /✗/ contained
syntax match qfWarn /!/ contained
syntax match qfInfo /i\ze / contained
syntax match qfHint /·/ contained
syntax match qfTag /\[\%(build\|vet\|lint\|agent\)\]/
highlight default link qfPath Directory
highlight default link qfSep Comment
highlight default link qfPos LineNr
highlight default link qfError DiagnosticError
highlight default link qfWarn DiagnosticWarn
highlight default link qfInfo DiagnosticInfo
highlight default link qfHint DiagnosticHint
highlight default link qfTag Comment
]])
