return {
  {
    'glepnir/lspsaga.nvim',
    branch = "main",
    keys = {
      {"gh", "<cmd>Lspsaga finder<CR>"},
      {"<leader>ca", "<cmd>Lspsaga code_action<CR>", mode = {"n","v"}},
      {"K", "<cmd>Lspsaga hover_doc<CR>"},
      {"<C-f>", function() require'lspsaga'.action.smart_scroll_with_saga(1)end},
      {"<C-b>", function() require'lspsaga'.action.smart_scroll_with_saga(-1)end},
      {"gs", function() require('lspsaga').signaturehelp.signature_help() end},
      {"<Leader>lr", "<cmd>Lspsaga rename<CR>"},
      {"<Leader>ld", function () require'lspsaga'.provider.preview_definition() end},
      {"<leader>ld", "<cmd>Lspsaga show_line_diagnostics<CR>"},
      {"<leader>lb", "<cmd>Lspsaga show_buf_diagnostics<CR>"},
      {"<leader>lw", "<cmd>Lspsaga show_workspace_diagnostics<CR>"},
      {"<leader>cc", "<cmd>Lspsaga show_cursor_diagnostics<CR>"},
      {"[e", "<cmd>Lspsaga diagnostic_jump_prev<CR>"},
      {"]e", "<cmd>Lspsaga diagnostic_jump_next<CR>"},
      {"[E",
        [[<cmd>lua require("lspsaga.diagnostic"):goto_prev({severity = vim.diagnostic.severity.ERROR})<CR>]]},
      {"]E",
        [[<cmd>lua require("lspsaga.diagnostic"):goto_prev({severity = vim.diagnostic.severity.ERROR})<CR>]]},
      { "<A-q>", "<cmd>Lspsaga term_toggle<CR>", mode = {"t", "n"}},
      {"<leader>gp", "<cmd>Lspsaga peek_definition<CR>"},
      {"<leader>lo", "<cmd>Lspsaga outline<CR>"},
      {"gd", "<cmd>Lspsaga goto_definition<CR>"}
    },
    config = true,
    dependencies = {
      'nvim-treesitter/nvim-treesitter', -- optional
      'nvim-tree/nvim-web-devicons',     -- optional
    }
  },
    "folke/lazydev.nvim",
  ft = "lua", -- only load on lua files
  opts = {
    library = {
      -- See the configuration section for more details
      -- Load luvit types when the `vim.uv` word is found
      { path = "${3rd}/luv/library", words = { "vim%.uv" } },
    },
  },
  "mrcjkb/rustaceanvim",
  {'neovim/nvim-lspconfig',
    dependencies = {
      'mfussenegger/nvim-dap',
      'p00f/clangd_extensions.nvim',
      {'williamboman/mason.nvim', dependencies = {'hrsh7th/cmp-nvim-lsp'}},
      'williamboman/mason-lspconfig.nvim',
      --{'simrat39/rust-tools.nvim', event = 'BufEnter *.rs'},
    },
    config = function()
      --end of LSPSAGA CONFIGURATION

      -- Diagnostic keymaps
      --[[vim.keymap.set('n', '[d', vim.diagnostic.goto_prev)
    vim.keymap.set('n', ']d', vim.diagnostic.goto_next)
    vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float)
    vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist)
    --]]
      -- LSP settings.
      --  This function gets run when an LSP connects to a particular buffer.
      -- See `:help vim.diagnostic.*` for documentation on any of the below functions

      vim.diagnostic.config({
        virtual_text = {
          source = "if_many",
        },
        update_in_insert = true,
        signs = true,
        underline = true,
        severity_sort = true,
        float = {
          border = 'rounded',
          source = 'always',
          header = '',
          prefix = '',
        }
      })

      -- Allow to have a floating window with the errors
      -- vim.cmd([[
      -- set signcolumn=yes
      -- autocmd CursorHold * lua vim.diagnostic.open_float(nil, { focusable = false })
      -- ]])

      local lsp_keymaps = function (bufnr)
        -- NOTE: Remember that lua is a real programming language, and as such it is possible
        -- to define small helper and utility functions so you don't have to repeat yourself
        -- many times.
        --
        -- In this case, we create a function that lets us more easily define mappings specific
        -- for LSP related items. It sets the mode, buffer and description for us each time.
        local nmap = function(keys, func, desc)
          if desc then
            desc = 'LSP: ' .. desc
          end

          vim.keymap.set('n', keys, func, { buffer = bufnr, desc = desc })
        end

        nmap('<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame')
        --nmap('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction')

        --nmap('gd', vim.lsp.buf.definition, '[G]oto [D]efinition')
        nmap('gi', vim.lsp.buf.implementation, '[G]oto [I]mplementation')
        nmap('gr', require('telescope.builtin').lsp_references, '[T]elescope [R]eferences')
        nmap('<leader>ds', require('telescope.builtin').lsp_document_symbols, '[D]ocument [S]ymbols')
        nmap('<leader>ws', require('telescope.builtin').lsp_dynamic_workspace_symbols, '[W]orkspace [S]ymbols')

        -- See `:help K` for why this keymap
        --nmap('K', vim.lsp.buf.hover, 'Hover Documentation')
        nmap('<C-k>', vim.lsp.buf.signature_help, 'Signature Documentation')

        -- Lesser used LSP functionality
        nmap('gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')
        nmap('<leader>D', vim.lsp.buf.type_definition, 'Type [D]efinition')
        nmap('<leader>wa', vim.lsp.buf.add_workspace_folder, '[W]orkspace [A]dd Folder')
        nmap('<leader>wr', vim.lsp.buf.remove_workspace_folder, '[W]orkspace [R]emove Folder')
        nmap('<Leader>lf', '<cmd>:Format<CR>', '[F]ormat whole buffer')
        nmap('<leader>wl', function()
          print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
        end, '[W]orkspace [L]ist Folders')

        -- Create a command `:Format` local to the LSP buffer
        vim.api.nvim_buf_create_user_command(bufnr, 'Format', function(_)
          if vim.lsp.buf.format then
            vim.lsp.buf.format()
          elseif vim.lsp.buf.formatting then
            vim.lsp.buf.formatting()
          end
        end, { desc = 'Format current buffer with LSP' })
      end

      local on_attach = function(_, bufnr)
        lsp_keymaps(bufnr)
      end

      -- require("neodev").setup({
      -- })
      --vim.keymap.set('n', '<cmd>:Format<cr>', {buffer = bufnr, desc='LSP: [F]ormat whole buffer' })
      -- nvim-cmp supports additional completion capabilities
      local capabilities = require('cmp_nvim_lsp').default_capabilities(vim.lsp.protocol.make_client_capabilities())

      -- Setup mason so it can manage external tooling
      require('mason').setup()

      -- Enable the following language servers

      local servers = {'pyright', 'ts_ls', 'yamlls', 'lua_ls', 'angularls', 'bashls','autotools_ls', 'nil_ls',
        --'phpactor',
        --'emmet_ls',
        'emmet_language_server',
        'html', "phpactor",
        "clangd", "eslint", "tailwindcss", "cssls",
        --"jdtls"
      }
      -- Ensure the servers above are installed
      require('mason-lspconfig').setup {
        ensure_installed = servers,
      }

      -- for _, lsp in ipairs(servers) do
      --   --require('lspconfig')[lsp].setup {
      --   vim.lsp.config[lsp] {
      --     on_attach = on_attach,
      --     capabilities = capabilities,
      --   }
      -- end
      vim.lsp.config("*", {
        on_attach=on_attach,
        capabilities = capabilities,
        })

      require("clangd_extensions").setup()
      --require'lspconfig'.emmet_ls.setup({
      vim.lsp.config["emmet_ls"] = {
        on_attach = on_attach,
        capabilities = capabilities,
        filetypes = { "html", "php", "typescriptreact", "javascriptreact", "css", "sass", "scss", "less", "typescript"},
      }

      -- require'lspconfig'.cssls.setup{
      --   on_attach = on_attach,
      --   capabilities = capabilities,
      -- }

      --require'lspconfig'.lua_ls.setup {
      vim.lsp.config['lua_ls'] = {
        settings = {
          Lua = {
            runtime = {
              -- Tell the language server which version of Lua you're using (most likely LuaJIT in the case of Neovim)
              version = 'LuaJIT',
            },
            diagnostics = {
              -- Get the language server to recognize the `vim` global
              globals = {'vim'},
            },
            workspace = {
              -- Make the server aware of Neovim runtime files
              library = vim.api.nvim_get_runtime_file("", true),
              checkThirdPAry = false,
            },
            -- Do not send telemetry data containing a randomized but unique identifier
            telemetry = {
              enable = false,
            },
            completion = {
              callSnippet = "Replace",
            },
          },
        },
      }

      vim.lsp.config['nil_ls'] = {
        settings = {
          ['nil'] = {
            nix = {
              flake = {
                autoArchive = true,
              },
            },
          },
        },
      }

      --[[ -- Update this path
      -- for rust debugger watch rust-tools
      local extension_path = vim.env.HOME .. '/.vscode-oss/extensions/vadimcn.vscode-lldb-1.8.1-universal/'
      local codelldb_path = extension_path .. 'adapter/codelldb'
      local liblldb_path = extension_path .. 'lldb/lib/liblldb.so'  -- MacOS: This may be .dylib

      local opts = {
        -- ... other configs
        dap = {
          adapter = require('rust-tools.dap').get_codelldb_adapter(
            codelldb_path, liblldb_path)
        }
      }
      local rt = require("rust-tools")

      rt.setup({
        opts,
        server = {
          capabilities = capabilities,
          on_attach = function(_, bufnr)
            --lsp_keymaps(bufnr)

            -- Hover actions
            vim.keymap.set("n", "<Leader>r", rt.hover_actions.hover_actions, { buffer = bufnr })
            -- Code action groups
            vim.keymap.set("n", "<Leader>a", rt.code_action_group.code_action_group, { buffer = bufnr })
          end,
          setting = {
            [""ust-analyzer"] = {
              checkOnSave = {
                command = "clippy"
              },
              diagnostics = {
                experimental = {
                  enable = true,
                }
              }
            }
          }
        },
      }) ]]
    end,
  },
  {
    "folke/trouble.nvim",
    -- opts will be merged with the parent spec
    opts = { use_diagnostic_signs = true },
    cmd = "Trouble",
    keys = {
      {
        "<leader>xx",
        "<cmd>Trouble diagnostics toggle<cr>",
        desc = "Diagnostics (Trouble)",
      },
      {
        "<leader>xX",
        "<cmd>Trouble diagnostics toggle filter.buf=0<cr>",
        desc = "Buffer Diagnostics (Trouble)",
      },
      {
        "<leader>cs",
        "<cmd>Trouble symbols toggle focus=false<cr>",
        desc = "Symbols (Trouble)",
      },
      {
        "<leader>cl",
        "<cmd>Trouble lsp toggle focus=false win.position=right<cr>",
        desc = "LSP Definitions / references / ... (Trouble)",
      },
      {
        "<leader>xL",
        "<cmd>Trouble loclist toggle<cr>",
        desc = "Location List (Trouble)",
      },
      {
        "<leader>xQ",
        "<cmd>Trouble qflist toggle<cr>",
        desc = "Quickfix List (Trouble)",
      },
    },
  },
  -- add symbols-outline
  {
    "simrat39/symbols-outline.nvim",
    cmd = "SymbolsOutline",
    keys = { { "<leader>cs", "<cmd>SymbolsOutline<cr>", desc = "Symbols Outline" } },
    config = true,
  },
}
