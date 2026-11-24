local parser_install_dir =
vim.fn.stdpath("data") .. "/treesitter-parsers"
-- Keep norg/norg_meta OUT of this list.
--
-- Neorg parsers live separately under:
--   ~/.local/share/nvim/neorg-parsers/parser/
--
-- nvim-treesitter exclusively manages parser_install_dir.
local parsers = {
  "c",
  "cpp",
  "go",
  "lua",
  "python",
  "rust",
  "typescript",
  "php",
  "html",
  "css",
  "javascript",
  "latex",
  "bash",
  "regex",
  "markdown",
  "markdown_inline",
  "java",
  "vim",
  "vimdoc",
  "angular",
}
return {
  "nvim-treesitter/nvim-treesitter",
  branch = "main",
  lazy = false,
  build = ":TSUpdate",

  dependencies = {
    {
      "nvim-treesitter/nvim-treesitter-textobjects",
      branch = "main",
    },
  },

  config = function()
    local treesitter = require("nvim-treesitter")


    -- nvim-treesitter main automatically prepends install_dir
    -- to runtimepath.
    treesitter.setup {
      install_dir = parser_install_dir,
    }

    -- Replaces ensure_installed.
    --
    -- install() is a no-op for parsers that are already installed,
    -- so doing this on startup is fine.
    treesitter.install(parsers)

    ---------------------------------------------------------------------------
    -- Highlighting + indentation
    ---------------------------------------------------------------------------

    local group = vim.api.nvim_create_augroup(
      "ox_treesitter",
      { clear = true }
    )

    vim.api.nvim_create_autocmd("FileType", {
      group = group,

      callback = function(args)
        -- Only enable Tree-sitter when a parser exists for this filetype.
        local ok = pcall(vim.treesitter.start, args.buf)

        if ok then
          vim.bo[args.buf].indentexpr =
          "v:lua.require'nvim-treesitter'.indentexpr()"
        end
      end,
    })

    ---------------------------------------------------------------------------
    -- Incremental selection
    --
    -- Neovim 0.12 implements this natively now.
    ---------------------------------------------------------------------------

    -- Start selecting the smallest Tree-sitter node.
    vim.keymap.set("n", "<C-Space>", function()
      vim.cmd("normal! v")
      vim.treesitter.select("parent")
    end, {
        desc = "Tree-sitter: start incremental selection",
      })

    -- Grow selection.
    vim.keymap.set("x", "<C-Space>", function()
      vim.treesitter.select("parent")
    end, {
        desc = "Tree-sitter: increment selection",
      })

    -- Shrink selection.
    vim.keymap.set("x", "<C-Backspace>", function()
      vim.treesitter.select("child")
    end, {
        desc = "Tree-sitter: decrement selection",
      })

    ---------------------------------------------------------------------------
    -- Textobjects
    ---------------------------------------------------------------------------

    require("nvim-treesitter-textobjects").setup {
      select = {
        lookahead = true,
      },

      move = {
        set_jumps = true,
      },
    }

    ---------------------------------------------------------------------------
    -- Textobject selection
    ---------------------------------------------------------------------------

    local select =
    require("nvim-treesitter-textobjects.select")

    vim.keymap.set({ "x", "o" }, "af", function()
      select.select_textobject("@function.outer", "textobjects")
    end)

    vim.keymap.set({ "x", "o" }, "if", function()
      select.select_textobject("@function.inner", "textobjects")
    end)

    vim.keymap.set({ "x", "o" }, "ac", function()
      select.select_textobject("@class.outer", "textobjects")
    end)

    vim.keymap.set({ "x", "o" }, "ic", function()
      select.select_textobject("@class.inner", "textobjects")
    end)

    -- Replacement for the old scope_incremental mapping.
    vim.keymap.set("x", "<C-s>", function()
      select.select_textobject("@local.scope", "locals")
    end, {
        desc = "Tree-sitter: select scope",
      })

    ---------------------------------------------------------------------------
    -- Textobject movement
    ---------------------------------------------------------------------------

    local move =
    require("nvim-treesitter-textobjects.move")

    vim.keymap.set({ "n", "x", "o" }, "]m", function()
      move.goto_next_start("@function.outer", "textobjects")
    end)

    vim.keymap.set({ "n", "x", "o" }, "]]", function()
      move.goto_next_start("@class.outer", "textobjects")
    end)

    vim.keymap.set({ "n", "x", "o" }, "]M", function()
      move.goto_next_end("@function.outer", "textobjects")
    end)

    vim.keymap.set({ "n", "x", "o" }, "][", function()
      move.goto_next_end("@class.outer", "textobjects")
    end)

    vim.keymap.set({ "n", "x", "o" }, "[m", function()
      move.goto_previous_start("@function.outer", "textobjects")
    end)

    vim.keymap.set({ "n", "x", "o" }, "[[", function()
      move.goto_previous_start("@class.outer", "textobjects")
    end)

    vim.keymap.set({ "n", "x", "o" }, "[M", function()
      move.goto_previous_end("@function.outer", "textobjects")
    end)

    vim.keymap.set({ "n", "x", "o" }, "[]", function()
      move.goto_previous_end("@class.outer", "textobjects")
    end)

    ---------------------------------------------------------------------------
    -- Parameter swapping
    ---------------------------------------------------------------------------

    local swap =
    require("nvim-treesitter-textobjects.swap")

    vim.keymap.set("n", "<leader>a", function()
      swap.swap_next("@parameter.inner")
    end)

    vim.keymap.set("n", "<leader>A", function()
      swap.swap_previous("@parameter.inner")
    end)
  end,
}
