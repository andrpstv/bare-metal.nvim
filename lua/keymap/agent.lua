-- keymap/agent — CLI-агенты рядом с кодом (sidekick.nvim) и ревью их правок.
--
-- План и решения: docs/distro/34-agent-workflow.md. Плагин грузится только
-- из обработчика: пока агент не нужен, старт за него не платит. Отправка из
-- x-mode — функцией, а не через ":": иначе visual mode закрывается раньше,
-- чем sidekick прочитает выделение, и уходит только позиция курсора.

local map = vim.keymap.set

local function cli()
	if not require("distro.loader").load("sidekick.nvim") then
		return nil
	end
	return require("sidekick.cli")
end

map("n", "<leader>Aa", function()
	local c = cli()
	return c and c.toggle({ focus = true })
end, { noremap = true, silent = true, desc = "agent: Toggle window" })
map("n", "<leader>An", function()
	local c = cli()
	return c and c.select({ focus = true })
end, { noremap = true, silent = true, desc = "agent: Pick / start CLI" })
map({ "n", "x" }, "<leader>As", function()
	local c = cli()
	return c and c.send({ msg = "{this}" })
end, { noremap = true, silent = true, desc = "agent: Send reference (file:lines)" })
map("x", "<leader>Av", function()
	local c = cli()
	return c and c.send({ msg = "{this}\n{selection}" })
end, { noremap = true, silent = true, desc = "agent: Quote selection (ref + text)" })
map({ "n", "x" }, "<leader>Ap", function()
	local c = cli()
	return c and c.prompt()
end, { noremap = true, silent = true, desc = "agent: Prompt library" })

-- Ревью правок агента (dev.agent): база сессии = снимок дерева в момент старта.
map("n", "<leader>Ab", function()
	require("dev.agent").start()
end, { noremap = true, silent = true, desc = "agent: Start review session / reset base to now" })
map("n", "<leader>Aq", function()
	require("dev.agent").quickfix()
end, { noremap = true, silent = true, desc = "agent: Changes since session start → quickfix" })
map("n", "<leader>Ad", function()
	require("dev.agent").diffview()
end, { noremap = true, silent = true, desc = "agent: Diffview since session start" })
map("n", "<leader>Ae", function()
	require("dev.agent").stop()
end, { noremap = true, silent = true, desc = "agent: End review session" })

-- Открыли агента — сессия ревью стартует сама (вне git — молча). Событие шлёт
-- sidekick; пока он не загружен, автокоманда ничего не стоит.
vim.api.nvim_create_autocmd("User", {
	group = vim.api.nvim_create_augroup("AgentReview", { clear = true }),
	pattern = "SidekickCliAttach",
	desc = "agent: auto-start review session when an agent window opens",
	callback = function()
		require("dev.agent").ensure()
	end,
})
