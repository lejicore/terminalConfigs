local M = {}

function M.execute_macro_over_visual_range()
  local char = vim.fn.getchar()
  local macro_key = vim.fn.nr2char(char --[[@as integer]])

  print("@", macro_key)

  vim.cmd.normal({ args = { "@" .. macro_key }, range = { "'<", "'>" } })
end

vim.keymap.set("x", "@", M.execute_macro_over_visual_range, { noremap = true })

return M
