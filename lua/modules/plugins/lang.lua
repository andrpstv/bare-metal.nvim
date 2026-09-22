local lang = {}

-- Минимум для Go: go.nvim (команды :GoTest/:GoFillStruct/...) + nvim-lint (golangci-lint).
-- Сам LSP (gopls) настраивается в completion/servers/gopls.lua, бинарник — системный.
-- Убрано: bqf, rustaceanvim, crates, render-markdown, markdown-preview,
-- obsidian, translate.
lang["ray-x/go.nvim"] = {
	lazy = true,
	ft = { "go", "gomod", "gosum" },
	build = ":GoInstallBinaries",
	config = require("lang.go"),
	dependencies = "ray-x/guihua.lua",
}
lang["mfussenegger/nvim-lint"] = {
	lazy = true,
	event = { "BufReadPost", "BufNewFile" },
	config = require("lang.lint"),
}

return lang
