-- dev.gomod — module operations with real feedback.
-- Why this exists: go.nvim's :GoModTidy sends the CURRENT (.go) buffer
-- URI to gopls.tidy (which expects go.mod URIs) with a 2s timeout, so on
-- real projects <leader>gm silently does nothing. This runs the real
-- `go mod tidy` in the enclosing module root instead.
local M = {}

---@param path string file path to start from
---@return string? module root dir
local function mod_root(path)
	local dir = vim.fn.fnamemodify(path, ":p:h")
	local found = vim.fs.find("go.mod", { upward = true, path = dir })
	if not found or #found == 0 then
		return nil
	end
	return vim.fn.fnamemodify(found[1], ":p:h")
end

--- Run `go mod tidy` for the module enclosing the current buffer.
function M.tidy()
	local root = mod_root(vim.api.nvim_buf_get_name(0))
	if not root then
		vim.notify("[go] no go.mod above current file", vim.log.levels.WARN, { title = "go" })
		return
	end
	vim.notify("[go] go mod tidy: " .. root, vim.log.levels.INFO, { title = "go" })
	vim.system({ "go", "mod", "tidy" }, { cwd = root, text = true }, function(res)
		vim.schedule(function()
			if res.code == 0 then
				vim.notify("[go] tidy clean", vim.log.levels.INFO, { title = "go" })
			else
				local raw = (res.stderr ~= "" and res.stderr) or res.stdout or ""
				vim.notify("[go] tidy FAILED: " .. raw:gsub("%s+$", ""):sub(1, 300), vim.log.levels.ERROR, { title = "go" })
			end
		end)
	end)
end

return M
