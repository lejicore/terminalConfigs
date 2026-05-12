{ pkgs }:
with pkgs;
let
  common-packages = import ../common/packages.nix { pkgs = pkgs; };
in

common-packages
++ [
  wget
  gnugrep
  tree
  # needed for Emacs to use --dired in ls commands
  coreutils
  docker-compose
  (writeShellScriptBin "coc-db-up" ''
    set -euo pipefail
    exec docker compose -f ~/terminalConfigs/.dotfiles/nix/dev/postgres/coc-war-bot.compose.yml up -d
  '')
  (writeShellScriptBin "coc-db-down" ''
    set -euo pipefail
    exec docker compose -f ~/terminalConfigs/.dotfiles/nix/dev/postgres/coc-war-bot.compose.yml down
  '')
  (writeShellScriptBin "coc-db-logs" ''
    set -euo pipefail
    exec docker compose -f ~/terminalConfigs/.dotfiles/nix/dev/postgres/coc-war-bot.compose.yml logs -f postgres
  '')
  (writeShellScriptBin "coc-db-reset" ''
    set -euo pipefail
    exec docker compose -f ~/terminalConfigs/.dotfiles/nix/dev/postgres/coc-war-bot.compose.yml down -v
  '')
]
