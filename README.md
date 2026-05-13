# Personal terminal and desktop configuration

This repository contains personal dotfiles, shell tooling, editor setup, and desktop configuration managed primarily with [GNU Stow](https://www.gnu.org/software/stow/). It also includes a Nix flake for `home-manager` and `nix-darwin` based machines.

The repo is opinionated and host-specific in a few places, but it is structured well enough to reuse selectively package by package.

## What is here

The main content lives under [`.dotfiles`](./.dotfiles). Each top-level directory is a Stow package that maps files into `$HOME`.

Notable packages in this repo:

- `zsh`: shell startup files, aliases, Powerlevel10k config, ssh-agent bootstrap, WSL/macOS/Linux environment handling
- `tmux`: tmux configuration
- `wezterm`, `kitty`, `iterm2`: terminal emulator configs
- `emacs`: Emacs configs
- `nvim`: Neovim configs
- `ranger`, `ueberzugpp`: terminal file manager and image preview support
- `awesome`, `dunst`, `volumeicon`: Linux desktop/window manager notification stack
- `aerospace`: macOS window manager config
- `direnv`: `direnv` integration
- `surfingkeys`, `tridactyl`, `tridactyl_mac`, `vimium`: browser keyboard workflow configs
- `scripts`: personal helper scripts installed into the shell environment
- `nix`: flake-based system and home configuration

## Repository layout

```text
.
├── README.md
└── .dotfiles/
    ├── zsh/
    ├── tmux/
    ├── wezterm/
    ├── emacs/
    ├── awesome/
    ├── scripts/
    ├── nix/
    └── ...
```

This is a mixed-environment setup. Parts are intended for:

- Linux desktop systems, especially AwesomeWM-based setups
- macOS, including `nix-darwin`, WezTerm, iTerm2, and Aerospace
- WSL2, with custom display/audio handling in the shell config

## Requirements

At minimum:

- `git`
- `stow`

Useful depending on which packages you enable:

- `zsh`
- `tmux`
- `wezterm` or `kitty`
- `direnv`
- `nix` with flakes enabled
- `home-manager`
- `nix-darwin` on macOS

## Quick start

Clone the repository:

```bash
git clone <your-repo-url> ~/terminalConfigs
cd ~/terminalConfigs
```

Initialize submodules if you want the bundled dependencies:

```bash
git submodule update --init --recursive
```

Then move into the Stow root and symlink the packages you want:

```bash
cd ~/terminalConfigs/.dotfiles
stow zsh tmux wezterm
```

To add more packages later:

```bash
stow scripts ranger direnv
```

To remove a package:

```bash
stow -D wezterm
```

To restow after editing:

```bash
stow -R zsh
```

## Suggested rollout

Start with the low-risk packages first:

```bash
cd ~/terminalConfigs/.dotfiles
stow zsh tmux direnv scripts
```

Then add editor and terminal packages:

```bash
stow wezterm kitty emacs nvim
```

Finally add desktop-specific packages only on the correct platform:

- Linux: `awesome dunst volumeicon ueberzugpp`
- macOS: `aerospace iterm2`
- Browser configs: `surfingkeys tridactyl tridactyl_mac vimium`

## Nix configuration

The Nix setup lives in [`.dotfiles/nix`](./.dotfiles/nix) and includes:

- a flake
- `home-manager` integration
- `nix-darwin` integration
- overlays
- secret handling with `sops-nix`
- machine-specific Darwin modules

Common entry files:

- [`flake.nix`](./.dotfiles/nix/flake.nix)
- [`home.nix`](./.dotfiles/nix/home.nix)

Example commands:

```bash
cd ~/terminalConfigs/.dotfiles/nix
nix flake show
home-manager switch --flake .#<user>
darwin-rebuild switch --flake .#Personal-Darwin-Air
```

Important caveats for this Nix setup:

- It is not a generic starter flake.
- Some values are user-specific and host-specific.
- The flake currently references local paths and secret material.
- Secret decryption expects `sops`/`age` files to exist in the expected locations.

You should review `flake.nix`, `home.nix`, `secrets.nix`, and the `darwin/` modules before trying to apply this on another machine.

## Scripts

The `scripts` package contains helper commands under [`.dotfiles/scripts/scripts/bin`](./.dotfiles/scripts/scripts/bin), including utilities for:

- tmux session selection
- Home Manager shortcuts
- notifications
- quick shell helpers

These become available after stowing the `scripts` package if the target path is on your `PATH`.

## Submodules

This repository uses git submodules for some dependencies, including:

- helper script repositories
- other external tooling

If something appears to be missing after cloning, run:

```bash
git submodule update --init --recursive
```

## Notes and caveats

- This is a living personal repo, not a polished distribution.
- Some files are experimental, backup copies, or machine-specific.
- The AwesomeWM setup includes custom notes about patching upstream Awesome libraries.
- The shell config assumes tools like `oh-my-zsh`, `powerlevel10k`, `cowsay`, `fortune`, `lolcat`, and others may already be installed.
- The Nix configuration contains references that should be sanitized before sharing publicly.

## Customization

If you want to reuse this repo without taking everything:

1. Clone it to a temporary location.
2. Pick only the packages you actually want.
3. Review each package before stowing it.
4. Remove host-specific values from shell and Nix configs.
5. Restow only the cleaned packages.

## Maintenance

Typical update flow:

```bash
cd ~/terminalConfigs
git pull
git submodule update --init --recursive
cd .dotfiles
stow -R zsh tmux wezterm scripts
```

## License

No license is currently declared in this repository. Treat the contents as personal configuration unless a license file is added.
