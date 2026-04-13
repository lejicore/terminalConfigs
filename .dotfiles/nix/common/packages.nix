{ pkgs }:
with pkgs;
let
  nvimWithMagick = symlinkJoin {
    name = "nvim-with-magick";
    paths = [ neovim ];
    nativeBuildInputs = [ makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/nvim \
        --prefix LUA_PATH ';' "${luajitPackages.magick}/share/lua/5.1/?.lua;${luajitPackages.magick}/share/lua/5.1/?/init.lua;;" \
        --prefix LUA_CPATH ';' "${luajitPackages.magick}/lib/lua/5.1/?.so;;" \
        --prefix DYLD_FALLBACK_LIBRARY_PATH ':' "${imagemagick}/lib"
    '';
  };
in
[
  home-manager
  #ranger
  tree-sitter
  nvimWithMagick
  yazi
  tmux
  fzf
  cowsay
  fortune
  toilet
  lolcat
  fd
  jq
  yq
  ripgrep
  lazygit
  lsd
  nodenv
  pipx
  #rustup
  rust-bin.nightly.latest.default
  stow
  kitty
  wezterm
  chafa
  gnupg
  atuin
  pyenv
  zsh-history-substring-search
  luarocks
  luajit
  sops
  age
  # openssh
  prettier
  emacsLejiWithPackages
  emacsPackages.cask
  jansson
  telegram-desktop
  gawk
  #floorp
  tor
  yt-dlp
  aria2
  mpv
  aider-chat
  texliveFull
  bat
  typescript
  nodemon
  nixd # nix lsp server
  nixfmt # nix formatter
  #direnv
  # emacsPackages.treesit-grammars.with-all-grammars

  # tree-sitter-grammars.tree-sitter-php
  go
  codex
  poppler-utils # getting pdftotext
  vips # Used to get images previews in Dirvish
  ffmpegthumbnailer # Used to get previews on videofiles in Dirvish
  mediainfo # Used to get previews on audio in Dirvish

  #mupdf
  copilot-language-server
  bash-language-server
  eza
  hyperfine
  claude-code
  claude-agent-acp
  codex-acp
  socat
]
