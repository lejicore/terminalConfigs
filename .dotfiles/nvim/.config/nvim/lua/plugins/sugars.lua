return {
  {'tridactyl/vim-tridactyl'},
  -- {
  --   'glacambre/firenvim',
  --
  --   -- Lazy load firenvim
  --   -- Explanation: https://github.com/folke/lazy.nvim/discussions/463#discussioncomment-4819297
  --   lazy = not vim.g.started_by_firenvim,
  --   build = function()
  --     vim.fn["firenvim#install"](0)
  --   end
  -- },

  {'nvim-tree/nvim-tree.lua',
    dependencies = {'nvim-tree/nvim-web-devicons'},
    keys = {
      {"<leader>nl", function() require'nvim-tree.api'.marks.list() end,
        desc = "Retrive all marked nodes."},

      {"<leader>nn", function() require'nvim-tree.api'.marks.navigate.next() end,
        desc = "Navigate to the next marked node, wraps. Opens files as per |nvim-tree.actions.open_file| Works best with |nvim-tree.update_focused_file| enabled. "},

      {"<leader>np", function() require'nvim-tree.api'.marks.navigate.prev() end,
        desc = "As per nvim-tree-api.marks.navigate.next()"},

      {"<leader>ns", function() require'nvim-tree.api'.marks.navigate.select() end,
        desc = "    Prompts for selection of a marked node as per |nvim-tree-api.marks.navigate.next()| "},

      {"<leader>ne", '<cmd>NvimTreeToggle<CR>'},
      {"<leader>nf", '<cmd>NvimTreeFindFile<CR>'}
    },
    opts = {
      renderer = {
        special_files = { "Cargo.toml", "Makefile", "README.md", "readme.md", "MAKEFILE" },
      }
    }
  }, -- for file icons

  {'numToStr/Comment.nvim',
    opts = {
      -- add any options here
    },
    --lazy = false,
  },
  {'tpope/vim-apathy',
    lazy = true},
  event = "InsertEnter",
  {'lambdalisue/suda.vim'},
  {'brooth/far.vim'}, --asynchronous search and replace operations on a set of files
  {'Shougo/echodoc.vim'}, --print completed documention
  {'Shougo/context_filetype.vim'}, --add context filype feature
  {'tpope/vim-surround'}, --useging that allow to surround text
  { 's1n7ax/nvim-terminal',
    config = function()
      -- following option will hide the buffer when it is closed instead of deleting
      -- the buffer. This is important to reuse the last terminal buffer
      -- IF the option is not set, plugin will open a new terminal every single time
      vim.o.hidden = true

      require('nvim-terminal').setup({
        window = {
          -- Do `:h :botright` for more information
          -- NOTE: width or height may not be applied in some "pos"
          position = 'botright',

          -- Do `:h split` for more information
          split = 'sp',

          -- Width of the terminal
          width = 50,

          -- Height of the terminal
          height = 15,
        },

        -- keymap to disable all the default keymaps
        disable_default_keymaps = false,

        -- keymap to toggle open and close terminal window
        toggle_keymap = '<leader>;',

        -- increase the window height by when you hit the keymap
        window_height_change_amount = 2,

        -- increase the window width by when you hit the keymap
        window_width_change_amount = 2,

        -- keymap to increase the window width
        increase_width_keymap = '<leader><leader>+',

        -- keymap to decrease the window width
        decrease_width_keymap = '<leader><leader>-',

        -- keymap to increase the window height
        increase_height_keymap = '<leader>+',

        -- keymap to decrease the window height
        decrease_height_keymap = '<leader>-',

        terminals = {
          -- keymaps to open nth terminal
          {keymap = '<leader><C-1>'},
          {keymap = '<leader><C-2>'},
          {keymap = '<leader><C-3>'},
          {keymap = '<leader><C-4>'},
          {keymap = '<leader><C-5>'},
        },
      })
    end,
  },

  {
    'smoka7/hop.nvim',
    --branch = 'v1', -- optional but strongly recommended
    version = "*",
    opts = {
      keys = 'etovxqpdygfblzhckisuran'
    },
    keys = {
      {"<leader>hh", "<cmd>HopWord<CR>", desc = "[J]ump to a word" },
      {"<leader>e", "<cmd>HopChar1<CR>", desc = "[J]ump to a pattern of 1 character" },
      {"<leader>hp", "<cmd>HopPattern<CR>", desc = "[J]ump to a pattern of x characters" },
      {"<leader>hw", "<cmd>HopChar2<CR>", desc = "[J]ump to a pattern of 2 character" }
    }
  },

  {'ThePrimeagen/harpoon',

    dependencies = {'nvim-lua/plenary.nvim'},
    keys = {
      {"<Leader>p", function() require'harpoon.mark'.add_file() end, desc = "[H]arpoon a [File]"},
      {"<Leader>H", function() require'harpoon.ui'.toggle_quick_menu() end, desc = "[T]oggle [H]arpoon [M]enu"},
      {"<Leader>1", function() require'harpoon.ui'.nav_file(1) end, desc = "[G]oto [H]arpooned [F]ile 1"},
      {"<Leader>2", function() require'harpoon.ui'.nav_file(2) end, desc = "[G]oto [H]arpooned [F]ile 2"},
      {"<Leader>3", function() require'harpoon.ui'.nav_file(3) end, desc = "[G]oto [H]arpooned [F]ile 3"},
      {"<Leader>4", function() require'harpoon.ui'.nav_file(4) end, desc = "[G]oto [H]arpooned [F]ile 4"},
      {"<Leader>5", function() require'harpoon.ui'.nav_file(5) end, desc = "[G]oto [H]arpooned [F]ile 5"},
      {"<Leader>6", function() require'harpoon.ui'.nav_file(6) end, desc = "[G]oto [H]arpooned [F]ile 6"},
      {"<Leader>7", function() require'harpoon.ui'.nav_file(7) end, desc = "[G]oto [H]arpooned [F]ile 7"},
      {"<Leader>8", function() require'harpoon.ui'.nav_file(8) end, desc = "[G]oto [H]arpooned [F]ile 8"}

    },
    opts = {

    }
  },
  {
    "leath-dub/snipe.nvim",
    keys = {
      {"<Leader>t", function () require("snipe").open_buffer_menu() end, desc = "Open Snipe buffer menu"}
    },
    opts = {}
  },
  {'nvim-pack/nvim-spectre',
    dependencies = {'nvim-lua/plenary.nvim'},
    enabled = true,
    keys = {
      {"<leader>S", function() require'spectre'.toggle()end, desc= "Toggle Spectre"},
      {"<leader>sw", function() require'spectre'.open_visual({select_word=true})end, desc= "Search current word"},
      {"<leader>sp", function() require'spectre'.open_file_search({select_word=true})end, desc= "Search on current file"},
    }
  },
  {
    'mikesmithgh/kitty-scrollback.nvim',
    enabled = true,
    lazy = true,
    cmd = { 'KittyScrollbackGenerateKittens', 'KittyScrollbackCheckHealth' },
    -- version = '*', -- latest stable version, may have breaking changes if major version changed
    -- version = '^1.0.0', -- pin major version, include fixes and features that do not have breaking changes
    config = function()
      require('kitty-scrollback').setup()
    end,
  },
  {
    "folke/zen-mode.nvim",
    keys = {
      {"\\z", "<cmd>ZenMode<cr>", desc="Activate ZenMode"}
    },
    opts = {
      -- your configuration comes here
      -- or leave it empty to use the default settings
      -- refer to the configuration section below
      window = {
        backdrop = 1,
        width=.50,
        height=1,
        options = {
          number = false,
          relativenumber = false
        }
      }
    }
  },
  -- Following plugins goyo.vim and true-zen.nvim are like zen-mode.
  -- I just prefer actually using zen-mode
  --[[ {
    'junegunn/goyo.vim',
    config = function ()
      vim.g.goyo_height=120
      vim.g.goyo_width=50
    end
  },
  {
    "Pocco81/true-zen.nvim",
    opts={
      modes = {
        ataraxis = {
          minimum_writing_area = {
            width=50,
          },
        }

      }
    }
  } ]]
}
