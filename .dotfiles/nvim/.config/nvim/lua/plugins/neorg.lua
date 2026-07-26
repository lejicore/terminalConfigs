return {
  "nvim-neorg/neorg",
  enabled = true,
  lazy = false,
  version = "*",
  build = ":Neorg sync-parsers",
  dependencies = { "nvim-lua/plenary.nvim", 'hrsh7th/nvim-cmp', 'luarocks.nvim', 'nvim-treesitter/nvim-treesitter' },
  config = function()
    require('neorg').setup {
      load = {
        ["core.defaults"] = {},
        ["core.export"] = {},
        ["core.dirman"] = {
          config = {
            workspaces = {
              work = "~/notes/work",
              home = "~/notes/home",
              games = "~/notes/games"
            }
          }
        },
        ['core.completion'] = {
          config = {
            engine = "nvim-cmp",
          }
        },
        ['core.concealer'] = {
          config = {
            icon_preset = "diamond",
            folds = false,
            dim_code_blocks = {
              enabled = true,
              content_only = true
            }
          }
        },
        ['core.ui.calendar'] = {},
        ['core.integrations.image'] = {},
        ['core.latex.renderer'] = {},
      },
    }
  end,
}
