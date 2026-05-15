if vim.fn.has("nvim") == 1 then
	-- Use nvim 0.9+ new loader with byte-compilation cache
	-- https://neovim.io/doc/user/lua.html#vim.loader
	if vim.loader then
		vim.loader.enable()
	end
end
--vim.o.clipboard=vim.opt.clipboard:prepend { "unnamedplus" }
vim.opt.clipboard:prepend({ "unnamedplus" })

-- Following is only for WSL2
--[[ local function is_wsl()
    -- Check if the WSL_DISTRO_NAME environment variable is set, which indicates a WSL environment
    return (os.getenv("WSL_DISTRO_NAME") ~= nil)
end
if is_wsl() then
  vim.g.clipboard = {
  name = "win32yank-wsl",
  copy = {
    ["+"] = "win32yank.exe -i --crlf",
    ["*"] = "win32yank.exe -i --crlf"
  },
  paste = {
    ["+"] = "win32yank.exe -o --crlf",
    ["*"] = "win32yank.exe -o --crlf"
  },
  cache_enable = 0,
}
end ]]

--vim.o.wildmenu --Show a bar that you can use to expand searches with tabs set by
--defaut on neovim
vim.cmd([[let $PATH = '$HOME/.nodenv/versions/16.10.0/bin:' . $PATH]])
vim.g.python3_host_prog = "~/.pyenv/versions/neovim3/bin/python"
vim.g.html_indent_script1 = "inc" --better indentation for hml using javascript
vim.g.html_indent_style1 = "inc" --better indentation for html using css
--vim.o.path=vim.o.path .. "**"  --allow to search a file with :find command on all subdirectories
vim.o.nu = true --Add lines number
vim.o.relativenumber = true
vim.opt.ignorecase = true
vim.g.suda_smart_edit = 1
--vim.o.relativenumber
-- To use ripgrep for the grep functions
-- And format it well useful for quickfix
vim.o.grepprg = "rg --vimgrep"
vim.o.grepformat = "%f:%l:%c:%m,%f|%l col %c|%m"
vim.o.cursorline = false
vim.opt.background = "dark"
vim.o.laststatus = 2
--vim.o.incsearch=false --show searching as typing
vim.o.hlsearch = false -- highliting or no the searches
--vim.o.statusline=[[ %F%m%r%h%w\ [FORMAT=%{&ff}]\ [TYPE=%Y]\ [ASCII=\%0.3b]\ [HEX=\%02.2B]\ [POS=%04v]\ [%p%%]\ [LEN=%L] ]]
--vim.cmd([[syntax on ]]) --Add syntax
--vim.opt.autoindent=true
--vim.opt.cpoptions:append "I"
-- vim.cmd([[ set cpoptions+=I ]])
vim.o.smartindent = true
vim.o.encoding = "utf-8"
vim.o.expandtab = true --use always tab
vim.opt.termguicolors = true
-- vim.o.formatoptions=vim.o.formatoptions .. "j" --remove comment leader when joining comments
-- vim.o.formatoptions=vim.o.formatoptions .. "n" --smart auto-indenting inside numbered of lists

--detetec when the files have been change outside of vim or by another buffer of this file
vim.opt.autoread = true

--vim.opt.formatoptions:remove ( "r", "o", "c"}
vim.opt.formatoptions:remove({ "r", "o" })
vim.opt.formatoptions:append({ "j", "n" })
vim.o.hidden = true --hide unsaved buffers when changing buffer
vim.cmd([[ set nojoinspaces ]])
vim.cmd([[ set directory^="$HOME/tmp/.nvim/swp//" ]])
vim.o.showcmd = true
--vim.o.foldmethod="manual"
vim.o.foldexpr = "nvim_treesitter#foldexpr()"
vim.o.foldmethod = "expr"
vim.o.foldlevel = 99
--vim.cmd([[ set foldignore=]])
vim.opt.completeopt = "menu,menuone,noinsert" --complete options
--vim.cmd([[ let g:completion_matching_strategy_list=["exact", "substring", "fuzzy"] ]])--how completion fill the menu

--vim.g.material_style = "palenight"
-- vim.cmd([[
-- colorscheme material
-- ]]) --use the  gruvbox colortheme

--managing normal mode movements
vim.o.whichwrap = "b,h,l,s,<,>,[,],~"
--managing visual mode
vim.o.virtualedit = "block" --allow the cursor to move where there is not text
--managing buffers and tab
vim.o.switchbuf = "usetab" --try to reuse windows/tabs when opening a file in a buffer
vim.o.tabstop = 2 --spaces per tab

--liste chars (changing appearance of space, tab etc)
-- vim.o.list=true --show whitespace
-- vim.o.listchars="nbsp:☠"
-- vim.cmd([[
-- set listchars+=tab:>-
-- set listchars+=extends:»
-- set listchars+=precedes:«
-- set listchars+=trail:•
-- let &showbreak='+++'
-- ]])

--vim.o.showbreak='⤷'

-- Save undo history
vim.o.undofile = true

-- Decrease update time
vim.o.updatetime = 250
vim.wo.signcolumn = "number"

--neovim messages management
vim.opt.shortmess = "aAWF"
--vim.cmd([[ set shortmess="+=A" ]])--ignore swapfiles messages

--tab length and behavior managing
vim.o.shiftround = true --always indent by multiple of shiftwidth
vim.o.shiftwidth = 2 --space per tab
vim.o.smarttab = true
vim.o.softtabstop = -1 --use shiftwidth for tabs/bse

--scrolling around corner
vim.o.scrolloff = 0 --start scrolling 3 lines before edge of viewport
vim.o.sidescrolloff = 3

-- [[ Highlight on yank ]]
-- See `:help vim.highlight.on_yank()`
local highlight_group = vim.api.nvim_create_augroup("YankHighlight", { clear = true })
vim.api.nvim_create_autocmd("TextYankPost", {
	callback = function()
		vim.highlight.on_yank()
	end,
	group = highlight_group,
	pattern = "*",
})
