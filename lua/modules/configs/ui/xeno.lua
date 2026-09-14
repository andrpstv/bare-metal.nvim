return function()
if (vim.g.colors_name or ""):find("khold") then return end
local xeno = require("xeno")

xeno.color("rust", "#b5622f")
xeno.color("amber", "#c99a3f")
xeno.color("brick", "#a4453c")
xeno.color("umber", "#7a5c42")
xeno.color("olive", "#6f7a4a")
xeno.color("moss", "#8a9463")

xeno.theme("metal", {
background = "#2b2d2e",
accent = "#c17a3d",
foreground = "#c6cac7",
properties = { contrast = -0.15, chroma = -0.15, lightness = -0.05 },

highlights = {
editor = {
CursorLineNr = { fg = "@amber.100", bold = true },
MatchParen = { fg = "@brick.100", bold = true },
},
syntax = {
Comment = { fg = "@foreground.400", italic = true },
Keyword = { fg = "@umber.300" },
Conditional = { fg = "@brick.300" },
Function = { fg = "@amber.300" },
Type = { fg = "@rust.200" },
String = { fg = "@olive.100" },
Number = { fg = "@amber.100" },
Boolean = { fg = "@amber.100" },
Variable = { fg = "@foreground.300" },
Property = { fg = "@moss.300" },
Operator = { fg = "@rust.300" },
Punctuation = { fg = "@foreground.400" },

["@keyword"] = { link = "Keyword" },
["@keyword.return"] = { link = "Keyword" },
["@keyword.function"] = { link = "Conditional" },
["@keyword.conditional"] = { link = "Conditional" },
["@keyword.repeat"] = { link = "Conditional" },
["@keyword.operator"] = { fg = "@rust.300" },
["@keyword.import"] = { fg = "@umber.400" },

["@function"] = { link = "Function" },
["@function.builtin"] = { fg = "@amber.100" },
["@type"] = { link = "Type" },
["@string"] = { link = "String" },
["@string.escape"] = { fg = "@amber.100" },
["@number"] = { link = "Number" },
["@boolean"] = { link = "Boolean" },
["@constant"] = { fg = "@amber.100" },
["@constant.builtin"] = { fg = "@amber.100", bold = true },

["@variable"] = { link = "Variable" },
["@variable.builtin"] = { fg = "@brick.200" },
["@property"] = { link = "Property" },
["@constructor"] = { fg = "@foreground.400" },
["@lsp.type.variable"] = { link = "@variable" },
["@lsp.type.property"] = { link = "@property" },
["@lsp.mod.declaration"] = { clear = true },

["@operator"] = { link = "Operator" },
["@punctuation"] = { link = "Punctuation" },
["@punctuation.bracket"] = { link = "Punctuation" },
["@punctuation.delimiter"] = { link = "Punctuation" },
},
},
})

vim.cmd("colorscheme metal")
end
