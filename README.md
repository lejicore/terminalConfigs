# Personal NixOS, macOS and terminal configuration

This repository contains my personal **Nix-first system, development environment, and dotfiles configuration**.

The primary setup is built around:

* **NixOS**
* **Home Manager**
* **nix-darwin** on macOS
* Nix flakes
* reusable Nix modules
* overlays
* declarative package and application configuration
* secret management with `sops-nix`

The repository also keeps the underlying dotfiles organized as **GNU Stow-compatible packages**.

That is intentional: **Stow is the fallback, not the primary configuration system.**

A machine without Nix can still reuse most shell, editor, terminal, browser, and desktop configuration directly through symlinks, but the complete setup is obtained through Nix.

## Configuration model

The repository effectively has two ways to consume the configuration.

### Nix — primary

On NixOS, macOS, or another machine using Home Manager, Nix is the preferred entry point.

It manages the configuration declaratively and can provide considerably more than simply linking files into `$HOME`, including:

* package installation
* Home Manager configuration
* NixOS configuration
* nix-darwin configuration
* host-specific modules
* overlays
* secrets
* application integration
* generated configuration
* platform-dependent behavior
* reproducible environments

The Nix configuration lives under:

```text
.dotfiles/nix/
```

### GNU Stow — fallback

The dotfiles are deliberately still laid out as Stow packages.

This means much of the repository remains usable on systems where I do not want Nix managing the machine.

For example:

```bash
cd ~/.dotfiles
stow zsh tmux nvim kitty
```

This installs the corresponding configuration through ordinary symlinks.

The Stow setup is useful for:

* quickly reusing one configuration package
* machines without Nix
* temporary environments
* selectively importing parts of the repository
* manually managed systems

It does **not necessarily reproduce every feature of the Nix setup**.

Some configuration, packages, host integration, secrets, generated state, or other Nix-specific conveniences only exist on the declarative path.

## Repository layout

The main configuration lives under [`.dotfiles`](./.dotfiles).

```text
.
├── README.md
└── .dotfiles/
    ├── nix/
    ├── zsh/
    ├── tmux/
    ├── wezterm/
    ├── kitty/
    ├── emacs/
    ├── nvim/
    ├── awesome/
    ├── scripts/
    └── ...
```

The important distinction is:

```text
.dotfiles/nix/
    declarative system and Home Manager configuration

.dotfiles/<package>/
    underlying application configuration, generally also usable
    directly through GNU Stow
```

## Platforms

This repository is used across several environments.

### NixOS

NixOS is the main Linux configuration path.

The Nix configuration is intended to manage both the operating system and user environment declaratively.

Some desktop configuration in the repository targets an AwesomeWM-based Linux environment, including:

* AwesomeWM
* Dunst
* Volumeicon
* terminal tooling
* shell environment
* editors
* user services and utilities

### macOS

macOS is configured through **nix-darwin + Home Manager**.

The repository also contains configuration for macOS-specific software such as:

* Aerospace
* iTerm2
* WezTerm
* Kitty

### Other Linux systems

Home Manager can be used independently of NixOS where appropriate.

Alternatively, individual dotfile packages can simply be installed with Stow.

### WSL

Parts of the shell configuration also contain WSL-specific handling, including display and audio environment setup.

## Nix configuration

The Nix configuration lives in:

[`.dotfiles/nix`](./.dotfiles/nix)

It contains the flake and the modules used to construct the supported systems and user environments.

Notable pieces include:

* Nix flake configuration
* NixOS configuration
* Home Manager configuration
* nix-darwin configuration
* overlays
* reusable modules
* host-specific configuration
* `sops-nix` secret handling

Common entry points include:

* [`flake.nix`](./.dotfiles/nix/flake.nix)
* [`home.nix`](./.dotfiles/nix/home.nix)

The exact available flake outputs are best inspected with:

```bash
cd ~/terminalConfigs/.dotfiles/nix
nix flake show
```

Depending on the machine, configuration can then be applied through commands such as:

```bash
home-manager switch --flake .#<user>
```

or on macOS:

```bash
darwin-rebuild switch --flake .#Personal-Darwin-Air
```

For NixOS hosts, use the appropriate NixOS configuration exposed by the flake, for example:

```bash
sudo nixos-rebuild switch --flake .#<host>
```

The actual host names and outputs in `flake.nix` remain authoritative.

## Dotfile packages

Outside of the Nix configuration, most application configuration is kept in conventional Stow-compatible directories.

Notable packages include:

* `zsh` — shell startup files, aliases, Powerlevel10k configuration, ssh-agent bootstrap, and Linux/macOS/WSL handling
* `tmux` — tmux configuration
* `wezterm` — WezTerm configuration
* `kitty` — Kitty configuration
* `iterm2` — iTerm2 configuration
* `emacs` — Emacs configuration
* `nvim` — Neovim configuration
* `ranger` — terminal file manager configuration
* `ueberzugpp` — terminal image-preview configuration
* `awesome` — AwesomeWM configuration
* `dunst` — Linux notification daemon configuration
* `volumeicon` — Linux volume tray configuration
* `aerospace` — macOS window manager configuration
* `direnv` — `direnv` integration
* `surfingkeys` — browser keyboard configuration
* `tridactyl` / `tridactyl_mac` — Firefox keyboard workflow
* `vimium` — browser keyboard configuration
* `scripts` — personal shell utilities
* `nix` — declarative NixOS/Home Manager/nix-darwin configuration

## Installation

Clone the repository:

```bash
git clone <your-repo-url> ~/terminalConfigs
cd ~/terminalConfigs
```

Initialize submodules:

```bash
git submodule update --init --recursive
```

From here, choose either the Nix path or the Stow fallback.

## Nix installation

If the target machine uses Nix, start by inspecting the flake:

```bash
cd ~/terminalConfigs/.dotfiles/nix
nix flake show
```

Do **not** blindly apply the configuration to another machine.

This is a personal configuration rather than a generic NixOS starter repository. Several modules contain assumptions about my machines, users, paths, secrets, and installed software.

Review at least:

```text
flake.nix
home.nix
secrets.nix
darwin/
```

and the relevant NixOS or host modules before using them elsewhere.

### Home Manager

Where an appropriate Home Manager output exists:

```bash
home-manager switch --flake .#<user>
```

### NixOS

For a configured NixOS host:

```bash
sudo nixos-rebuild switch --flake .#<host>
```

### macOS

For a configured nix-darwin host:

```bash
darwin-rebuild switch --flake .#Personal-Darwin-Air
```

## Stow-only installation

Nix is not required to use the ordinary dotfiles.

GNU Stow can install individual packages directly:

```bash
cd ~/terminalConfigs/.dotfiles
stow zsh tmux wezterm
```

Additional packages can be installed independently:

```bash
stow scripts ranger direnv
```

Editors:

```bash
stow emacs nvim
```

Desktop-specific packages should only be installed on suitable systems.

Linux examples:

```bash
stow awesome dunst volumeicon ueberzugpp
```

macOS examples:

```bash
stow aerospace iterm2
```

Browser configuration can also be selected independently:

```bash
stow surfingkeys tridactyl tridactyl_mac vimium
```

Remove a package with:

```bash
stow -D wezterm
```

Restow one after changing it:

```bash
stow -R zsh
```

## Nix versus Stow

Both approaches intentionally operate on much of the same configuration, but they serve different purposes.

| Nix                               | Stow                               |
| --------------------------------- | ---------------------------------- |
| Primary setup                     | Fallback                           |
| Declarative machine configuration | Dotfile symlinking                 |
| Installs packages                 | Does not install dependencies      |
| Home Manager integration          | Direct `$HOME` configuration       |
| NixOS integration                 | OS-independent                     |
| nix-darwin integration            | OS-independent                     |
| Host-specific modules             | Manual host handling               |
| Secret integration                | Secrets must be handled separately |
| Can generate configuration/state  | Links existing files               |
| Reproducible system environment   | Reusable raw application config    |

In other words:

```text
Nix = reproduce the environment
Stow = reuse the dotfiles
```

A Stow-only installation can therefore be perfectly usable, but it should not be expected to reproduce every convenience provided by the complete Nix configuration.

## Scripts

The `scripts` package contains personal helper commands under:

[`.dotfiles/scripts/scripts/bin`](./.dotfiles/scripts/scripts/bin)

These include utilities for things such as:

* tmux session selection
* Home Manager operations
* notifications
* shell workflow helpers

When using Stow directly, make sure the resulting binary directory is included in `$PATH`.

When using the Nix configuration, relevant scripts can instead be integrated into the managed environment.

## Submodules

Some dependencies and external tools are included as Git submodules.

Initialize or refresh them with:

```bash
git submodule update --init --recursive
```

If something expected from the repository appears to be missing after cloning, checking the submodules is a good first step.

## Secrets

Parts of the Nix configuration use `sops-nix` and `age`.

The repository assumes the appropriate encrypted secret files and decryption identities are available.

A cloned configuration therefore cannot necessarily reproduce one of my machines simply by evaluating the flake.

Review secret handling before deploying the configuration elsewhere.

Never replace encrypted secret material with plaintext merely to make a configuration evaluate.

## Requirements

The actual requirements depend heavily on how the repository is consumed.

### Nix path

Typically:

* Nix
* flakes support
* Home Manager where applicable
* NixOS for system-level Linux deployment
* nix-darwin for macOS system configuration
* `sops` / `age` where secrets are involved

Much of the remaining software is expected to be provided declaratively.

### Stow path

At minimum:

* Git
* GNU Stow

Applications corresponding to the selected packages must then be installed separately.

For example:

* Zsh
* tmux
* Emacs
* Neovim
* WezTerm
* Kitty
* direnv
* AwesomeWM

The shell configuration may also expect optional tools such as:

* Powerlevel10k
* Oh My Zsh
* `cowsay`
* `fortune`
* `lolcat`

and other utilities depending on the host.

## Reusing parts of the repository

This repository is intentionally modular enough that taking the whole configuration is not required.

For Nix users, individual modules or pieces of the Home Manager configuration can be adapted.

For non-Nix users, individual Stow packages can be copied or linked independently.

For example, somebody interested only in the terminal workflow could take:

```text
zsh
tmux
kitty
nvim
scripts
```

without adopting the NixOS or desktop configuration.

The important part is to inspect configuration before applying it: this repository describes my own environment and therefore contains assumptions that may not make sense elsewhere.

## Notes and caveats

* This is a living personal configuration, not a polished distribution.
* Nix is the primary configuration mechanism.
* GNU Stow exists deliberately as a portable fallback.
* A Stow-only installation does not provide every feature of the Nix setup.
* Some modules and files are host-specific.
* Some files are experimental or retained for compatibility.
* The AwesomeWM setup contains custom notes and modifications related to upstream Awesome libraries.
* Some shell configuration assumes optional external tools are already available when Nix is not managing them.
* The Nix configuration contains machine-specific paths, host names, users, and secret references that should be reviewed before reuse.

## Maintenance

For the Nix-managed machines, normal maintenance happens through the corresponding Nix configuration and rebuild commands.

The repository itself can be updated with:

```bash
cd ~/terminalConfigs
git pull
git submodule update --init --recursive
```

The appropriate system can then be rebuilt from:

```bash
cd .dotfiles/nix
```

using the relevant Home Manager, NixOS, or nix-darwin command.

For a Stow-only installation, packages can instead be restowed manually:

```bash
cd ~/terminalConfigs/.dotfiles
stow -R zsh tmux wezterm scripts
```

## License

No license is currently declared in this repository.

Unless a license file is added, treat the contents as personal configuration rather than generally licensed reusable software.
