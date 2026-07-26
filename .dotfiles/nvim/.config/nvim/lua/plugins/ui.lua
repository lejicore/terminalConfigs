-- The noice variable is responsible to activate noice.nvimui.
-- if noice.nvim is activated we will want to enable nvim-notify,
-- and customise lualine with lualine-so-fancy.nvim
local noice = false;
-- checking i neovim has been started by firenvim
if vim.g.started_by_firenvim then
  noice = false
end
return {
  {'lukas-reineke/indent-blankline.nvim', main = "ibl",
    config = function()
      vim.o.showbreak='⤷'
      vim.opt.list = true
      vim.opt.listchars:append "trail:•"
      -- enable break indent
      vim.o.breakindent = true
      -- vim.cmd [[highlight IndentBlanklineIndent1 guifg=#E06C75 gui=nocombine]]
      -- vim.cmd [[highlight IndentBlanklineIndent2 guifg=#E5C07B gui=nocombine]]
      -- vim.cmd [[highlight IndentBlanklineIndent3 guifg=#98C379 gui=nocombine]]
      -- vim.cmd [[highlight IndentBlanklineIndent4 guifg=#56B6C2 gui=nocombine]]
      -- vim.cmd [[highlight IndentBlanklineIndent5 guifg=#61AFEF gui=nocombine]]
      -- vim.cmd [[highlight IndentBlanklineIndent6 guifg=#C678DD gui=nocombine]]
      --
      -- require('indent_blankline').setup {
      --   --char = '┊',
      --   -- for example, context is off by default, use this to turn it on
      --   show_current_context = true,
      --   show_current_context_start = true,
      --   show_trailing_blankline_indent = false,
      --
      --   char_highlight_list = {
      --     "IndentBlanklineIndent1",
      --     "IndentBlanklineIndent2",
      --     "IndentBlanklineIndent3",
      --     "IndentBlanklineIndent4",
      --     "IndentBlanklineIndent5",
      --     "IndentBlanklineIndent6",
      --   },
      -- }
      local highlight = {
        "RainbowRed",
        "RainbowYellow",
        "RainbowBlue",
        "RainbowOrange",
        "RainbowGreen",
        "RainbowViolet",
        "RainbowCyan",
      }

      local hooks = require "ibl.hooks"
      -- create the highlight groups in the highlight setup hook, so they are reset
      -- every time the colorscheme changes
      hooks.register(hooks.type.HIGHLIGHT_SETUP, function()
        vim.api.nvim_set_hl(0, "RainbowRed", { fg = "#E06C75" })
        vim.api.nvim_set_hl(0, "RainbowYellow", { fg = "#E5C07B" })
        vim.api.nvim_set_hl(0, "RainbowBlue", { fg = "#61AFEF" })
        vim.api.nvim_set_hl(0, "RainbowOrange", { fg = "#D19A66" })
        vim.api.nvim_set_hl(0, "RainbowGreen", { fg = "#98C379" })
        vim.api.nvim_set_hl(0, "RainbowViolet", { fg = "#C678DD" })
        vim.api.nvim_set_hl(0, "RainbowCyan", { fg = "#56B6C2" })
      end)
      require("ibl").setup { indent = { highlight = highlight, char = "│"} }
    end
  },-- Add indentation guides even on blank lines
  {'nvim-lua/popup.nvim'},
  { 'gelguy/wilder.nvim', enabled = false,
    config = function()
      local wilder = require("wilder")
      wilder.setup({
        modes = {':', '/', '?'},
      })
      wilder.set_option('pipeline', {
        wilder.branch(
          wilder.cmdline_pipeline({
            -- sets the language to use, 'vim' and 'python' are supported
            language = 'python',
            -- 0 turns off fuzzy matching
            -- 1 turns on fuzzy matching
            -- 2 partial fuzzy matching (match does not have to begin with the same first letter)
            fuzzy = 1,
          }),
          wilder.python_search_pipeline({
            -- can be set to wilder#python_fuzzy_delimiter_pattern() for stricter fuzzy matching
            pattern = wilder.python_fuzzy_pattern(),
            -- omit to get results in the order they appear in the buffer
            sorter = wilder.python_difflib_sorter(),
            -- can be set to 're2' for performance, requires pyre2 to be installed
            -- see :h wilder#python_search() for more details
            engine = 're',
          }),
          wilder.python_file_finder_pipeline({
            -- to use ripgrep : {'rg', '--files'}
            -- to use fd      : {'fd', '-tf'}
            file_command = {'find', '.', '-type', 'f', '-printf', '%P\n'},
            -- to use fd      : {'fd', '-td'}
            dir_command = {'find', '.', '-type', 'd', '-printf', '%P\n'},
            -- use {'cpsm_filter'} for performance, requires cpsm vim plugin
            -- found at https://github.com/nixprime/cpsm
            filters = {'fuzzy_filter', 'difflib_sorter'},
          })
        ),
      })

      local gradient = {
        '#f4468f', '#fd4a85', '#ff507a', '#ff566f', '#ff5e63',
        '#ff6658', '#ff704e', '#ff7a45', '#ff843d', '#ff9036',
        '#f89b31', '#efa72f', '#e6b32e', '#dcbe30', '#d2c934',
        '#c8d43a', '#bfde43', '#b6e84e', '#aff05b'
      }

      for i, fg in ipairs(gradient) do
        gradient[i] = wilder.make_hl('WilderGradient' .. i, 'Pmenu', {{a = 1}, {a = 1}, {foreground = fg}})
      end
      wilder.set_option('renderer', wilder.popupmenu_renderer({
        -- highlighter applies highlighting to the candidates
        --highlighter = wilder.basic_highlighter(),
        left = {' ', wilder.popupmenu_devicons()},
        right = {' ', wilder.popupmenu_scrollbar()},
        pumblend = 0,
        highlights = {
          gradient = gradient, -- must be set
          -- selected_gradient key can be set to apply gradient highlighting for the selected candidate.
        },
        highlighter = wilder.highlighter_with_gradient({
          wilder.basic_highlighter(), -- or wilder.lua_fzy_highlighter(),
        }),
      },
        wilder.popupmenu_border_theme({
          highlights = {
            border = 'Normal', -- highlight to use for the border
          },
          -- 'single', 'double', 'rounded' or 'solid'
          -- can also be a list of 8 characters, see :h wilder#popupmenu_border_theme() for more details
          border = 'double',
        })
      ))

    end
  },
  {'rcarriga/nvim-notify',
    enabled=noice,
    keys = {
      {"<leader>o", function() require'notify'.dismiss({pending = false, silent = false}) end, desc = "[C]lose [N]otification",
      }
    },
    opts = {
      top_down = false,
      fps = 60,
      background_colour = "#000000"
    }
  },
  {"folke/noice.nvim",event = "VeryLazy",
    enabled = noice,
    dependencies = {'rcarriga/nvim-notify',
      'MunifTanjim/nui.nvim'},
    --config = function()
    opts = {
      --require("noice").setup({
      routes = {
        {
          view = "cmdline_output",
          filter = { find = "make -k && time ./%:p:h:t"},
          --filter = { find = "This is a java file."},
        },
        -- {
        --   view = "split",
        --   filter = { event = "msg_show", min_height = 20 },
        -- }
      },
      lsp = {
        -- override markdown rendering so that **cmp** and other plugins use **Treesitter**
        override = {
          ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
          ["vim.lsp.util.stylize_markdown"] = true,
          ["cmp.entry.get_documentation"] = true,
        },
      },
      -- you can enable a preset for easier configuration
      presets = {
        bottom_search = true, -- use a classic bottom cmdline for search
        command_palette = true, -- position the cmdline and popupmenu together
        long_message_to_split = true, -- long messages will be sent to a split
        inc_rename = false, -- enables an input dialog for inc-rename.nvim
        lsp_doc_border = false, -- add a border to hover docs and signature help
      },
      views = {
        cmdline_popup = {
          position = {
            row = 5,
            col = "50%",
          },
          size = {
            width = 60,
            height = "auto",
          },
        },
        popupmenu = {
          backend = "cmp",
          relative = "editor",
          position = {
            row = 8,
            col = "50%",
          },
          size = {
            width = 60,
            height = 10,
          },
          border = {
            style = "rounded",
            padding = { 0, 1 },
          },
          win_options = {
            winhighlight = { Normal = "Normal", FloatBorder = "DiagnosticInfo" },
          },
        },
      },
      --})

    }
    --end
  },
  {'nvim-lualine/lualine.nvim',
    dependencies = {
      'nvim-tree/nvim-web-devicons',
      'meuter/lualine-so-fancy.nvim'},
    opt = true,
    config = function()
      if noice then
        require('lualine').setup {
          options = {
            -- ... your lualine config
            --theme = 'material-nvim'
            theme = 'auto'
            -- ... your lualine config
          },
          sections = {
            lualine_a = {
              { "fancy_mode", width = 3 }
            },
            lualine_b = {
              { "fancy_branch" },
              { "fancy_diff" },
            },
            lualine_c = {
              { "fancy_cwd", substitute_home = true }
            },
            lualine_x = {
              { "fancy_macro" },
              { "fancy_diagnostics" },
              { "fancy_searchcount" },
              { "fancy_location" },
            },
            lualine_y = {
              { "fancy_filetype", ts_icon = "" }
            },
            lualine_z = {
              { "fancy_lsp_servers" }
            },
          }
        }
      elseif not noice then
        require('lualine').setup {
          options = {
            theme = 'auto'
          },
        }
      end
    end
  },

  -- -- color highlither for css
  -- {'norcalli/nvim-colorizer.lua',
  --   config = function()
  --     require 'colorizer'.setup()
  --   end
  -- },
  {
    "catgoose/nvim-colorizer.lua",
    event = { "BufReadPre", "BufNewFile" },
    opts = {},
  },
  {
    'isobit/vim-caddyfile',
  }
}
