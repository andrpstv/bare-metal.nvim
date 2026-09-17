local completion = {}

-- Минимальный LSP: только конфиги серверов.
-- Установка бинарников — системная (go install / brew), без mason.
-- Автодополнение — встроенное vim.lsp.completion (включается в core/event.lua на LspAttach).
completion["neovim/nvim-lspconfig"] = {
	lazy = true,
	event = { "BufReadPre", "BufNewFile" },
	config = require("completion.lsp"),
}

return completion
