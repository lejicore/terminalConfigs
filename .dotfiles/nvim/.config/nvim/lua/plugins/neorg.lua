return {
  "nvim-neorg/neorg",
  enabled = true,
  lazy = false,
  version = "*",
  dependencies = { "nvim-lua/plenary.nvim", 'hrsh7th/nvim-cmp', 'luarocks.nvim' },
  -- init = function()
  --   local parser_dir =
  --   vim.fn.stdpath("data") .. "/neorg-parsers"
  --
  --   vim.opt.runtimepath:prepend(parser_dir)
  -- end,
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
        -- Neorg / Neovim 0.12 / nvim-treesitter(main) compatibility workaround.
        --
        -- Neorg currently tries to discover norg/norg_meta parsers through
        -- package.cpath, while our parsers live on runtimepath under:
        --
        --   ~/.local/share/nvim/treesitter-parsers/parser/
        --
        -- This makes Neorg's parser detection/ownership unreliable with the new
        -- nvim-treesitter API. Let Neovim use the existing runtimepath parsers and
        -- prevent Neorg from trying to configure/detect them itself.
        --
        -- Upstream issue:
        --   nvim-neorg/neorg#1814
        --
        -- CHECK BEFORE REMOVING:
        --   https://github.com/nvim-neorg/neorg/issues/1814
        ["core.integrations.treesitter"] = {
          config = {
            configure_parsers = true,
            warn_missing_parsers = true,
          },
        },
      },
    }
  end,
}
