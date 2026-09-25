-- distroManager manifest — source of truth. No side effects on require.
-- Refs frozen from lazy-lock.json (2026-09-24). kind=start is eager, kind=opt lazy via packadd.
-- `config` is resolved by distro.loader: "themes.*" as-is, else "modules.configs." prefix.
-- `deps` are packadd'ed (and configured) before the parent. See docs/distro/01-architecture.md

local M = {}

--- All vendored plugins (26). lazy.nvim itself is intentionally excluded.
M.plugins = {
	-- UI: eager (needed before anything renders)
	{ name = "black-metal-theme-neovim", repo = "metalelf0/black-metal-theme-neovim", ref = "3a5522fbc7127c638ac8a98692cb83bbdf3594a9", branch = "main", kind = "start", config = "themes.black-metal-khold", strip = true },
	{ name = "nvim-web-devicons", repo = "nvim-tree/nvim-web-devicons", ref = "914decffe650296c87312c53b7933ecb86718499", branch = "master", kind = "start", strip = true },
	-- UI: lazy
	{ name = "gitsigns.nvim", repo = "lewis6991/gitsigns.nvim", ref = "8d79f2410c76e62b92e51c28c82e28c1c5a3daeb", branch = "main", kind = "opt", event = { "CursorHold", "CursorHoldI" }, config = "ui.gitsigns", strip = true },
	-- Completion
	{ name = "nvim-lspconfig", repo = "neovim/nvim-lspconfig", ref = "ffd261c09c3dabd0bf1a438f47a8ae3b22f3c3ff", branch = "master", kind = "opt", defer_idle = true, event = { "BufReadPre", "BufNewFile" }, config = "completion.lsp", strip = true },
	{
		name = "nvim-cmp",
		repo = "hrsh7th/nvim-cmp",
		ref = "2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3",
		branch = "main",
		kind = "opt",
		defer_idle = true,
		event = { "InsertEnter", "CmdlineEnter" },
		config = "completion.cmp",
		strip = true,
		deps = { "LuaSnip", "cmp_luasnip", "cmp-nvim-lsp", "cmp-path", "cmp-buffer", "cmp-cmdline" },
	},
	-- NOTE: GitHub tarballs exclude git submodules. LuaSnip needs deps/jsregexp*,
	-- resolved 2026-09-24 from LuaSnip@0abc8f3 gitlinks:
	-- jsregexp=558d5b567a8a6a391ec578f3e763f43fd4126abc,
	-- jsregexp005=dd65498ae2c29b882d6c02c0a30577b08d660b94,
	-- jsregexp006=b5a81e21d0875667ba2458ac8ae903afd5568698 (+ `make install_jsregexp`).
	{ name = "LuaSnip", repo = "L3MON4D3/LuaSnip", ref = "0abc8f390b278c3b4aabc4c004ac8a088b65cf24", branch = "master", kind = "opt", defer_idle = true, build = "make install_jsregexp", config = "completion.luasnip", strip = false, needs = { bins = { "make", "cc" } }, deps = { "friendly-snippets" } },
	{ name = "friendly-snippets", repo = "rafamadriz/friendly-snippets", ref = "b4d01b0fdf3c9a549961c2f9ffe8dc09be166219", branch = "main", kind = "opt", defer_idle = true, strip = true },
	{ name = "cmp_luasnip", repo = "saadparwaiz1/cmp_luasnip", ref = "98d9cb5c2c38532bd9bdb481067b20fea8f32e90", branch = "master", kind = "opt", defer_idle = true, strip = true },
	{ name = "cmp-nvim-lsp", repo = "hrsh7th/cmp-nvim-lsp", ref = "cbc7b02bb99fae35cb42f514762b89b5126651ef", branch = "main", kind = "opt", defer_idle = true, strip = true },
	{ name = "cmp-path", repo = "hrsh7th/cmp-path", ref = "c642487086dbd9a93160e1679a1327be111cbc25", branch = "main", kind = "opt", defer_idle = true, strip = true },
	{ name = "cmp-buffer", repo = "hrsh7th/cmp-buffer", ref = "b74fab3656eea9de20a9b8116afa3cfc4ec09657", branch = "main", kind = "opt", defer_idle = true, strip = true },
	{ name = "cmp-cmdline", repo = "hrsh7th/cmp-cmdline", ref = "d126061b624e0af6c3a556428712dd4d4194ec6d", branch = "main", kind = "opt", defer_idle = true, strip = true },
	-- Editor
	{ name = "nvim-treesitter", repo = "nvim-treesitter/nvim-treesitter", ref = "cf12346a3414fa1b06af75c79faebe7f76df080a", branch = "master", kind = "opt", defer_idle = true, defer_until_idle = true, event = { "BufReadPre" }, build = "treesitter", config = "editor.treesitter", strip = false, needs = { bins = { "cc" } }, deps = { "nvim-treesitter-textobjects" } },
	{ name = "nvim-treesitter-textobjects", repo = "nvim-treesitter/nvim-treesitter-textobjects", ref = "5ca4aaa6efdcc59be46b95a3e876300cfead05ef", branch = "master", kind = "opt", strip = true },
	{ name = "flash.nvim", repo = "folke/flash.nvim", ref = "5f0f270fdc7c5b0c21d903ee85b9cb06f2ac636a", branch = "main", kind = "opt", event = { "CursorHold", "CursorHoldI" }, config = "editor.flash", strip = true },
	{ name = "diffview.nvim", repo = "sindrets/diffview.nvim", ref = "4516612fe98ff56ae0415a259ff6361a89419b0a", branch = "main", kind = "opt", cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory", "DiffviewRefresh" }, config = "editor.diffview", strip = true, deps = { "plenary.nvim" } },
	{ name = "plenary.nvim", repo = "nvim-lua/plenary.nvim", ref = "74b06c6c75e4eeb3108ec01852001636d85a932b", branch = "master", kind = "opt", strip = true },
	-- Tool
	{ name = "mini.nvim", provides = { "mini.pick", "mini.extra" }, repo = "echasnovski/mini.nvim", ref = "561751e839b99a4baca36b9d963166b66d2536a6", branch = "main", kind = "opt", config = "tool.mini_pick", strip = true },
	{ name = "trouble.nvim", repo = "folke/trouble.nvim", ref = "bd67efe408d4816e25e8491cc5ad4088e708a69a", branch = "main", kind = "opt", cmd = { "Trouble", "TroubleToggle", "TroubleRefresh" }, config = "tool.trouble", strip = true, deps = { "nvim-web-devicons" } },
	-- Lang (Go)
	{ name = "go.nvim", repo = "ray-x/go.nvim", ref = "f5d1f11d4f616efbe2339286310bb89c4853d769", branch = "master", kind = "opt", defer_idle = true, ft = { "go", "gomod", "gosum" }, build = ":GoInstallBinaries", config = "lang.go", strip = true, deps = { "guihua.lua" } },
	{ name = "guihua.lua", repo = "ray-x/guihua.lua", ref = "4c513d5dac550af77034cced421967b393261509", branch = "master", kind = "opt", defer_idle = true, strip = true },
	{ name = "nvim-lint", repo = "mfussenegger/nvim-lint", ref = "3d55c8f67c6ae5c15e1042571e107c7a3d5c5f4e", branch = "master", kind = "opt", defer_idle = true, ft = { "go", "gomod", "gosum", "tmpl" }, config = "lang.lint", strip = true },
	{ name = "nvim-dap", repo = "mfussenegger/nvim-dap", ref = "cfa2d58f4537aca6ca83e2de1a0d9f1491121264", branch = "master", kind = "opt", defer_idle = true, ft = { "go", "gomod" }, config = "lang.dap", strip = true, deps = { "nvim-dap-go", "nvim-dap-ui" } },
	{ name = "nvim-dap-go", repo = "leoluz/nvim-dap-go", ref = "b4421153ead5d726603b02743ea40cf26a51ed5f", branch = "main", kind = "opt", defer_idle = true, strip = true },
	{ name = "nvim-dap-ui", repo = "rcarriga/nvim-dap-ui", ref = "cc9dd33aade7f20bae414d0cba163bc60d4d4b43", branch = "master", kind = "opt", defer_idle = true, strip = true, deps = { "nvim-nio" } },
	{ name = "nvim-nio", repo = "nvim-neotest/nvim-nio", ref = "edcc181a875301dd21840189aa2f2f9ad69fc172", branch = "master", kind = "opt", defer_idle = true, strip = true },
}

--- Binaries managed via Tools section (same confirm pipeline).
--- `release` tools resolve a GitHub release asset through the active source
--- (corporate mirrors serve them via url_template too); `url` tools use an
--- explicit (possibly templated) archive URL — e.g. corp-provided toolchains.
M.tools = {
	{ name = "curl", check = "curl", required = true },
	{ name = "tar", check = "tar", required = true },
	{ name = "rg", check = "rg" },
	{ name = "gcc", check = "gcc", alt = { "cc", "clang" } },
	{ name = "make", check = "make" },
	{ name = "go", check = "go" },
}

--- Find a tool spec by binary name.
function M.get_tool(name)
	for _, t in ipairs(M.tools) do
		if t.name == name then
			return t
		end
	end
end

--- Optional catalog: curated plugins available on demand via :DistroInstall.
--- NOT loaded at boot, NOT in lock status; shown in the :Distro Catalog section.
--- Same shape as plugins (kind should be "opt").
M.catalog = {
	{ catalog = true, name = "telescope.nvim", repo = "nvim-telescope/telescope.nvim", ref = "40aedd8a68c78a656a10a8d62d80c54af59420fb", branch = "master", kind = "opt", cmd = { "Telescope" }, config = "tool.telescope", strip = true, deps = { "plenary.nvim" }, desc = "fuzzy finder over lists" },
	{ catalog = true, name = "oil.nvim", repo = "stevearc/oil.nvim", ref = "b73018b75affd13fa38e2fc94ef753b465f770d7", branch = "master", kind = "opt", cmd = { "Oil" }, config = "tool.oil", strip = true, desc = "file manager as buffer" },
	{ catalog = true, name = "toggleterm.nvim", repo = "akinsho/toggleterm.nvim", ref = "9a88eae817ef395952e08650b3283726786fb5fb", branch = "main", kind = "opt", cmd = { "ToggleTerm" }, config = "tool.toggleterm", strip = true, desc = "terminal windows" },
	{ catalog = true, name = "which-key.nvim", repo = "folke/which-key.nvim", ref = "3aab2147e74890957785941f0c1ad87d0a44c15a", branch = "main", kind = "opt", event = { "CursorHold" }, config = "tool.whichkey", strip = true, desc = "keymap popup" },
	{ catalog = true, name = "todo-comments.nvim", repo = "folke/todo-comments.nvim", ref = "31e3c38ce9b29781e4422fc0322eb0a21f4e8668", branch = "main", kind = "opt", event = { "BufReadPre" }, config = "tool.todo", strip = true, deps = { "plenary.nvim" }, desc = "TODO/FIXME highlights" },
	{ catalog = true, name = "lualine.nvim", repo = "nvim-lualine/lualine.nvim", ref = "221ce6b2d999187044529f49da6554a92f740a96", branch = "master", kind = "opt", config = "ui.lualine", strip = true, deps = { "nvim-web-devicons" }, desc = "statusline (replaces builtin)" },
	{ catalog = true, name = "indent-blankline.nvim", repo = "lukas-reineke/indent-blankline.nvim", ref = "f1e186e44d3b7f9ae918008e2c28ce37c6023d2d", branch = "master", kind = "opt", event = { "BufReadPre" }, config = "ui.ibl", strip = true, desc = "indent guides (ibl)" },
	{ catalog = true, name = "neogit", repo = "NeogitOrg/neogit", ref = "5adc81b26232954cd7a90f158aa7844c18fc3165", branch = "master", kind = "opt", cmd = { "Neogit" }, config = "tool.neogit", strip = true, deps = { "plenary.nvim" }, desc = "git UI (magit-like)" },
	{ catalog = true, name = "nvim-tree.lua", repo = "nvim-tree/nvim-tree.lua", ref = "478c69c0fe253caea88de9c5e138bfa77395a59a", branch = "master", kind = "opt", cmd = { "NvimTreeToggle" }, config = "tool.ntree", strip = true, deps = { "nvim-web-devicons" }, desc = "file tree (netrw alternative)" },
}

--- Binaries (LSP servers, linters, formatters) for the :DistroBinaries menu.
--- method "go": `go install <pkg>` (needs Go + GOPROXY reachability).
--- method "release": GitHub release asset via curl (pin or latest-resolved tag);
---   in corporate mode requires explicit `url` (mirrors have no release API).
--- method "system": hint only (npm/brew/winget).
M.binaries = {
	{ name = "gopls", check = "gopls", method = "go", pkg = "golang.org/x/tools/gopls@latest", ver_args = { "version" }, desc = "Go language server" },
	{ name = "dlv", check = "dlv", method = "go", pkg = "github.com/go-delve/delve/cmd/dlv@latest", ver_args = { "version" }, desc = "Go debugger" },
	{ name = "staticcheck", check = "staticcheck", method = "go", pkg = "honnef.co/go/tools/cmd/staticcheck@latest", desc = "Go linter" },
	{
		name = "lua-language-server", check = "lua-language-server", method = "release",
		repo = "LuaLS/lua-language-server", asset = "lua-language-server-{ver}-{os}-{arch}.{ext}",
		asset_os = { darwin = "darwin", linux = "linux", windows = "win32" },
		asset_arch = { arm64 = "arm64", amd64 = "x64" }, asset_ext = "tar.gz",
		bin = "bin/lua-language-server", desc = "Lua language server",
	},
	{
		name = "stylua", check = "stylua", method = "release",
		repo = "JohnnyMorganz/StyLua", asset = "stylua-{os}-{arch}.{ext}",
		asset_os = { darwin = "macos", linux = "linux", windows = "windows" },
		asset_arch = { arm64 = "aarch64", amd64 = "x86_64" }, asset_ext = "zip",
		bin = "stylua", desc = "Lua formatter",
	},
	{
		name = "shfmt", check = "shfmt", method = "release",
		repo = "mvdan/sh", asset = "shfmt_{ver}_{os}_{arch}{exewin}",
		asset_os = { darwin = "darwin", linux = "linux", windows = "windows" },
		asset_arch = { arm64 = "arm64", amd64 = "amd64" },
		asset_ext = { darwin = "", linux = "", windows = ".exe" },
		bin = "shfmt", raw = true, desc = "shell formatter",
	},
	{
		name = "golangci-lint", check = "golangci-lint", method = "release",
		repo = "golangci/golangci-lint", asset = "golangci-lint-{vernov}-{os}-{arch}.{ext}",
		asset_os = { darwin = "darwin", linux = "linux", windows = "windows" },
		asset_arch = { arm64 = "arm64", amd64 = "amd64" }, asset_ext = "tar.gz",
		bin = "golangci-lint", strip = true, desc = "Go meta-linter",
	},
	{ name = "bashls", check = "bash-language-server", method = "system", desc = "bash language server (npm)" },
	{ name = "marksman", check = "marksman", method = "system", desc = "markdown language server" },
}

function M.get(name)
	for _, p in ipairs(M.plugins) do
		if p.name == name then
			return p
		end
	end
	-- on-demand catalog (loader.load/packadd works the same for it)
	for _, p in ipairs(M.catalog or {}) do
		if p.name == name then
			return p
		end
	end
end

return M
