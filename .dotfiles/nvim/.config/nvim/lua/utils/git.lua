local M = {}

function M.commit()
  local message = vim.fn.input("Enter commit message: ")
  if message == nil or message == "" then
    return
  end
  vim.fn.system({ "git", "commit", "-m", message })
end

vim.keymap.set("n", "<leader>ga", "<cmd>!git add %<CR>", { noremap = true, desc = "git add buffer" })
vim.keymap.set("n", "<leader>gr", "<cmd>!git reset %<CR>", { noremap = true, desc = "git reset buffer" })
vim.keymap.set("n", "<leader>gc", function()
  M.commit()
end, { noremap = true, desc = "git commit" })
vim.keymap.set("n", "<leader>gp", "<cmd>!git push<CR>", { noremap = true, desc = "git push" })

return M
