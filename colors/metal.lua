require("xeno").setup({
  background = "#2b2d2e",
  accent = "#c17a3d",
  properties = {
    contrast = -0.1,
    variation = 0.0,
    chroma = -0.1,
    lightness = -0.1,
  },
  transparent = false,
  foreground = "#c6cac7",
  _custom_colors = {
    umber = "#7a5c42",
    olive = "#6f7a4a",
    moss = "#8a9463",
    amber = "#c99a3f",
    rust = "#b5622f",
    brick = "#a4453c"
  },
  highlights = {
    syntax = {
      ["@keyword.import"] = {
        fg = "@umber.400"
      },
      ["@function"] = {
        link = "Function"
      },
      ["@function.builtin"] = {
        fg = "@amber.100"
      },
      ["@type"] = {
        link = "Type"
      },
      ["@string"] = {
        link = "String"
      },
      Function = {
        fg = "@amber.300"
      },
      ["@number"] = {
        link = "Number"
      },
      ["@boolean"] = {
        link = "Boolean"
      },
      ["@constant"] = {
        fg = "@amber.100"
      },
      ["@constant.builtin"] = {
        fg = "@amber.100",
        bold = true
      },
      ["@variable"] = {
        link = "Variable"
      },
      ["@variable.builtin"] = {
        fg = "@brick.200"
      },
      Operator = {
        fg = "@rust.300"
      },
      ["@property"] = {
        link = "Property"
      },
      ["@constructor"] = {
        fg = "@foreground.400"
      },
      ["@lsp.type.variable"] = {
        link = "@variable"
      },
      ["@lsp.type.property"] = {
        link = "@property"
      },
      Variable = {
        fg = "@foreground.300"
      },
      ["@operator"] = {
        link = "Operator"
      },
      ["@punctuation"] = {
        link = "Punctuation"
      },
      ["@punctuation.bracket"] = {
        link = "Punctuation"
      },
      ["@punctuation.delimiter"] = {
        link = "Punctuation"
      },
      String = {
        fg = "@olive.100"
      },
      Keyword = {
        fg = "@umber.300"
      },
      Conditional = {
        fg = "@brick.300"
      },
      Comment = {
        fg = "@foreground.400",
        italic = true
      },
      Type = {
        fg = "@rust.200"
      },
      Number = {
        fg = "@amber.100"
      },
      Property = {
        fg = "@moss.300"
      },
      ["@lsp.mod.declaration"] = {
        clear = true
      },
      Boolean = {
        fg = "@amber.100"
      },
      ["@string.escape"] = {
        fg = "@amber.100"
      },
      Punctuation = {
        fg = "@foreground.400"
      },
      ["@keyword"] = {
        link = "Keyword"
      },
      ["@keyword.return"] = {
        link = "Keyword"
      },
      ["@keyword.function"] = {
        link = "Conditional"
      },
      ["@keyword.conditional"] = {
        link = "Conditional"
      },
      ["@keyword.repeat"] = {
        link = "Conditional"
      },
      ["@keyword.operator"] = {
        fg = "@rust.300"
      }
    },
    editor = {
      CursorLineNr = {
        fg = "@amber.100",
        bold = true
      },
      MatchParen = {
        fg = "@brick.100",
        bold = true
      }
    }
  },
})
vim.g.colors_name = "metal"
