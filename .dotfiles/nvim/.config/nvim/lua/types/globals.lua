---@meta

---@class NvGlobals
---@field mapleader string
---@field maplocalleader string
---@field [string] any

---@class NvOptValue
local NvOptValue = {}

---@param value string
function NvOptValue:prepend(value) end

---@param value string
function NvOptValue:append(value) end

---@class NvOpt
---@field rtp NvOptValue
---@field runtimepath NvOptValue
---@field [string] any

---@type NvGlobals
vim.g = vim.g

---@type NvOpt
vim.opt = vim.opt

return {}
