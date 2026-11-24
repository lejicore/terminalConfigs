return {
  'nvim-orgmode/orgmode',
  event = 'VeryLazy',
  ft = { 'org' },
  config = function()
    -- Setup orgmode
    require('orgmode').setup({
      org_agenda_files = '~/org/org-files/**/*',
      org_default_notes_file = '~/org/org-files/refile.org',
      win_split_mode = {'float', 1},
      org_hide_leading_stars = true,
      org_startup_folded = "showeverything",
      --org_todo_keywords = {'TODO', 'NEXT', '|', 'DONE'},
      org_capture_templates = {
        t = {
          description = 'Todo',
          template = "* TODO %?\n  %U\n",
          target = '~/org/org-files/refile.org',
          headline = 'Inbox',
        },
        c = {
          description = 'Todo+file',
          template = "* TODO %?\n  %U\n  %a\n",
          target = '~/org/org-files/refile.org',
          headline = 'Inbox',
        }
      }
    })
    --vim.o.conceallevel = 3 -- highliting or no the searches


    -- NOTE: If you are using nvim-treesitter with ~ensure_installed = "all"~ option
    -- add ~org~ to ignore_install
    -- require('nvim-treesitter.configs').setup({
    --   ensure_installed = 'all',
    --   ignore_install = { 'org' },
    -- })
  end,
}
