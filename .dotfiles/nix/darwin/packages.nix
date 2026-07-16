{ pkgs }:
with pkgs;
let
  common-packages = import ../common/packages.nix { pkgs = pkgs; };
  metalvoice = pkgs.callPackage ../pkgs/metalvoice-bin.nix { };
in

common-packages
++ [
  metalvoice
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
  (writeShellScriptBin "coc-db-backup" ''
    set -euo pipefail
    cd ~/terminalConfigs/.dotfiles/nix/dev/postgres/
    if [ ! -d "backups" ]; then
        mkdir -p backups
    fi
    docker exec coc-war-bot-postgres pg_dump -U coc -d coc_war_bot -Fc > backups/coc_war_bot_$(date +%Y%m%d_%H%M%S).dump
  '')
]
