-- Please check `lua/core/settings.lua` to view the full list of configurable settings
local settings = {}

-- Examples
-- false осознанно: плагины склонированы по HTTPS, по SSH установка новых
-- падает с Permission denied (см. core/settings.lua).
settings["use_ssh"] = false

settings["colorscheme"] = "khold"

return settings
