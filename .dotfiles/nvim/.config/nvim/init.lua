require("types.globals")
vim.g.maplocalleader = " "
vim.g.mapleader = " "

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)


-- To required luarocks installed packages
--[[ package.path = package.path .. ";" .. vim.fn.expand("$HOME") .. "/.luarocks/share/lua/5.1/?/init.lua;"
package.path = package.path .. ";" .. vim.fn.expand("$HOME") .. "/.luarocks/share/lua/5.1/?.lua;" ]]

-- some plugins will be disabled if neovim has been spawned by firenvim vim.g.started_by_firenvim
require("lazy").setup("plugins",
{
  --defaults = {lazy = true },
  performance = {
    cache = {enabled = true},
    rtp = {
      disabled_plugins = {
        }
    }
  },
})
require("utils")
require("settings")
require("luasnip.loaders.from_vscode").lazy_load()
