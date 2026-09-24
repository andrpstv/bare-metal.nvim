-- core/distro — boot entry for distroManager. Wired into core/init.lua.
-- This module performs ZERO network I/O by construction (loader only).

local M = {}

function M.setup()
	require("distro.loader").boot()
	require("distro.init").setup()
end

return M
