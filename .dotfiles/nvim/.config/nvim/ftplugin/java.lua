-- ~/.config/nvim/ftplugin/java.lua

local jdtls = require("jdtls")

local uv = vim.uv or vim.loop
local home = uv.os_homedir() or vim.fn.expand("~")

local function path_join(...)
  return vim.fs.joinpath(...)
end

-- Your manual jdtls installation:
-- ~/.local/jdtls
local jdtls_dir = path_join(home, ".local", "jdtls")

-- Find the launcher jar dynamically, so updates don't break your config.
local launcher_jars = vim.fn.glob(
  path_join(jdtls_dir, "plugins", "org.eclipse.equinox.launcher_*.jar"),
  true,
  true
)

assert(
  #launcher_jars > 0,
  "jdtls launcher jar not found under: " .. path_join(jdtls_dir, "plugins")
)

local launcher = launcher_jars[1]

-- Pick the correct jdtls config directory for the OS.
local os_config = ({
  Linux = "config_linux",
  Darwin = "config_mac",
  Windows_NT = "config_win",
})[uv.os_uname().sysname]

assert(os_config, "Unsupported OS for jdtls: " .. uv.os_uname().sysname)

local config_dir = path_join(jdtls_dir, os_config)

-- Prefer the actual project root over cwd.
-- Add/remove markers depending on how your Java projects are structured.
local root_dir = vim.fs.root(0, {
  "mvnw",
  "gradlew",
  "pom.xml",
  "build.gradle",
  "settings.gradle",
  ".git",
})

if root_dir == nil then
  vim.notify("jdtls: root_dir not found", vim.log.levels.WARN)
  return
end

-- jdtls -data should be unique per project/workspace.
-- Using the full root path avoids collisions between projects with the same name.
local workspace_name = root_dir:gsub("[/\\:]", "_")
local workspace_dir = path_join(vim.fn.stdpath("cache"), "jdtls", workspace_name)

local config = {
  name = "jdtls",

  cmd = {
    -- jdtls itself currently needs Java 21+ to run.
    -- If `java` does not point to Java 21+, use an absolute path here.
    --
    -- Example:
    -- path_join(home, ".jdks", "jdk-21", "bin", "java")
    "java",

    "-Declipse.application=org.eclipse.jdt.ls.core.id1",
    "-Dosgi.bundles.defaultStartLevel=4",
    "-Declipse.product=org.eclipse.jdt.ls.core.product",
    "-Dlog.protocol=true",
    "-Dlog.level=ALL",
    "-Xmx1g",

    "--add-modules=ALL-SYSTEM",
    "--add-opens", "java.base/java.util=ALL-UNNAMED",
    "--add-opens", "java.base/java.lang=ALL-UNNAMED",

    "-jar", launcher,

    "-configuration", config_dir,

    "-data", workspace_dir,
  },

  root_dir = root_dir,

  settings = {
    java = {
      -- Put eclipse.jdt.ls settings here.
      --
      -- Example if your project targets older Java versions while jdtls runs on Java 21:
      --
      -- configuration = {
      --   runtimes = {
      --     {
      --       name = "JavaSE-17",
      --       path = "/path/to/jdk-17",
      --     },
      --   },
      -- },
    },
  },

  init_options = {
    bundles = {},
  },

  on_attach = function(_, bufnr)
    local map = vim.keymap.set
    local opts = { buffer = bufnr, silent = true }

    map("n", "<A-o>", jdtls.organize_imports, opts)

    map("n", "<leader>jv", jdtls.extract_variable, opts)
    map("x", "<leader>jv", function()
      jdtls.extract_variable(true)
    end, opts)

    map("n", "<leader>jc", jdtls.extract_constant, opts)
    map("x", "<leader>jc", function()
      jdtls.extract_constant(true)
    end, opts)

    map("x", "<leader>jm", function()
      jdtls.extract_method(true)
    end, opts)
  end,
}

jdtls.start_or_attach(config)
