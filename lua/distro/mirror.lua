-- distroManager mirror — github vs corporate source resolution. No network here.
-- Precedence: session (:DistroMirror set-*) > distro-mirror.local.json > env > settings.
-- Token: env (token_env) or session-only. NEVER persisted, NEVER logged unredacted.
-- Spec: docs/distro/06-corporate-mirror.md

local M = {}

M.GITHUB_TEMPLATE = "https://codeload.github.com/{owner}/{repo}/tar.gz/{ref}"
M.LOCAL_FILE = "distro-mirror.local.json"

-- session-only overrides (never written to disk; token never leaves memory)
local session = { enabled = nil, url_template = nil, extra_args = nil, token = nil }

function M.set_session(patch)
	for k, v in pairs(patch or {}) do
		session[k] = v
	end
end

function M.clear_session()
	session = { enabled = nil, url_template = nil, extra_args = nil, token = nil }
end

local function local_path()
	return vim.fn.stdpath("config") .. "/" .. M.LOCAL_FILE
end

function M.read_file()
	local f = io.open(local_path(), "r")
	if not f then
		return {}
	end
	local raw = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, raw)
	if ok and type(data) == "table" then
		-- token must never live in this file; drop it loudly if present
		if data.token ~= nil then
			data.token = nil
			vim.schedule(function()
				vim.notify("[Distro] token found in " .. M.LOCAL_FILE .. " — ignored and must be removed. Use env instead.", vim.log.levels.WARN)
			end)
		end
		return data
	end
	return {}
end

function M.write_file(tbl)
	tbl = tbl or {}
	tbl.token = nil -- never persist a token, even if passed by mistake
	local f = io.open(local_path(), "w")
	if not f then
		return false, "Cannot write to " .. local_path() .. " (permission denied). No changes made."
	end
	f:write(vim.json.encode(tbl))
	f:close()
	return true
end

local function split_args(s)
	local out = {}
	for a in (s or ""):gmatch("%S+") do
		out[#out + 1] = a
	end
	return out
end

--- Resolved effective config (no secrets inside except via token()).
---@return { enabled: boolean, url_template: string, extra_args: string[], token_env: string, allowed_hosts: string[], allow_http: boolean }
function M.effective()
	local defaults = require("core.settings").distro_mirror or {}
	local file = M.read_file()
	local env = vim.env
	local extra = nil
	if session.extra_args ~= nil then
		extra = session.extra_args
	elseif file.extra_args ~= nil then
		extra = file.extra_args
	elseif env.DISTRO_MIRROR_ARGS and env.DISTRO_MIRROR_ARGS ~= "" then
		extra = split_args(env.DISTRO_MIRROR_ARGS)
	else
		extra = defaults.extra_args or {}
	end
	local enabled
	if session.enabled ~= nil then
		enabled = session.enabled
	elseif file.enabled ~= nil then
		enabled = file.enabled
	elseif env.DISTRO_MIRROR == "1" then
		enabled = true
	else
		enabled = defaults.enabled or false
	end
	local template
	if session.url_template ~= nil then
		template = session.url_template
	elseif file.url_template ~= nil and file.url_template ~= "" then
		template = file.url_template
	elseif env.DISTRO_MIRROR_URL and env.DISTRO_MIRROR_URL ~= "" then
		template = env.DISTRO_MIRROR_URL
	else
		template = defaults.url_template or ""
	end
	return {
		enabled = enabled and template ~= "",
		url_template = template,
		extra_args = extra,
		token_env = defaults.token_env or "DISTRO_MIRROR_TOKEN",
		allowed_hosts = defaults.allowed_hosts or {},
		allow_http = defaults.allow_http or false,
	}
end

--- Token from session memory or env. Never stored, never returned in tables that get logged.
function M.token()
	if session.token and session.token ~= "" then
		return session.token
	end
	local env_name = (require("core.settings").distro_mirror or {}).token_env or "DISTRO_MIRROR_TOKEN"
	local v = vim.env[env_name]
	return (v and v ~= "") and v or nil
end

--- Fill template placeholders. Missing token -> empty string (caller must error first).
function M.fill(template, vars)
	vars = vars or {}
	local token = M.token() or ""
	local out = template
	out = out:gsub("{owner}", vars.owner or ""):gsub("{repo}", vars.repo or ""):gsub("{ref}", vars.ref or ""):gsub("{branch}", vars.branch or "main"):gsub("{token}", token)
	return out
end

function M.needs_token(template)
	return template:find("{token}", 1, true) ~= nil
end

--- Redact secrets for UI previews and logs. Call on EVERY string containing a URL.
function M.redact(s)
	s = tostring(s or "")
	s = s:gsub("token:[^@%s/]+", "token:<redacted>")
	s = s:gsub("(https?://)[^/%s@]+@", "%1<redacted>@")
	s = s:gsub("Authorization:[^%s]+", "Authorization:<redacted>")
	s = s:gsub("(Bearer )[^%s'\"]+", "%1<redacted>")
	return s
end

--- Short human-readable source label (token-free) for UI headers.
function M.label()
	local eff = M.effective()
	if not eff.enabled then
		return "github (codeload)"
	end
	return "corporate (" .. (M.host_of(eff.url_template) or "custom") .. ")"
end

function M.insecure(extra_args)
	for _, a in ipairs(extra_args or {}) do
		if a == "--insecure" or a == "-k" then
			return true
		end
	end
	return false
end

--- Extract lowercase host from a URL (drops userinfo). Returns nil when unparseable.
function M.host_of(url)
	local auth_host = tostring(url or ""):lower():match("^https?://([^/%s]+)")
	if not auth_host then
		return nil
	end
	return (auth_host:gsub("^[^@]+@", ""))
end

--- Safety gate for any resolved download URL. Refuses non-HTTPS (unless allow_http)
--- and hosts outside allowed_hosts (when the list is non-empty).
---@return boolean ok, string? err_or_host (host when ok)
function M.verify_url(url)
	url = tostring(url or "")
	local eff = M.effective()
	local scheme = url:match("^(%a+)://")
	if scheme ~= "https" and not (scheme == "http" and eff.allow_http) then
		return false, "Refusing non-HTTPS source. Only https:// is accepted (allow_http=false). No changes made."
	end
	local host = M.host_of(url)
	if not host then
		return false, "Refusing source with unparseable host. No changes made."
	end
	if eff.allowed_hosts and #eff.allowed_hosts > 0 then
		local needle = host:lower()
		for _, h in ipairs(eff.allowed_hosts) do
			if needle == h:lower() then
				return true, host
			end
		end
		return false, "Refusing host '" .. host .. "' — not in distro_mirror.allowed_hosts. No changes made."
	end
	return true, host
end

return M
