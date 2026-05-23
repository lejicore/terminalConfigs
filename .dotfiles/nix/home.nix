{
  config,
  pkgs,
  lib,
  ...
}:

let
  isDarwin = pkgs.stdenv.isDarwin;
  isLinux = pkgs.stdenv.isLinux;

  username = builtins.trace "configdir: ${config.rage.username}" config.rage.username;

  homeDir = if isDarwin then "/Users/${username}" else "/home/${username}";

  emacsDir = "${homeDir}/terminalConfigs/.dotfiles/emacs/.emacs.d";
  emacsBin = "${pkgs.emacsLejiWithPackages}/bin/emacs";

  pgrepBin = if isDarwin then "/usr/bin/pgrep" else "${pkgs.procps}/bin/pgrep";

  removePasswordScript = pkgs.writeShellScript "remove-password-after-syncthing" ''
    set -euo pipefail

    password_file="${homeDir}/.passwordFile"

    while ! ${pgrepBin} syncthing >/dev/null; do
      sleep 1
    done

    sleep 5

    if [ -f "$password_file" ]; then
      ${pkgs.coreutils}/bin/shred -u "$password_file"
    fi
  '';
in
lib.mkMerge [
  {
    # * Home Manager
    # use home manager as nix-darwin module, so that user profiles are built
    # together with the system when running darwin-rebuild

    home.username = username;
    home.homeDirectory = homeDir;

    home.enableNixpkgsReleaseCheck = false;
    home.stateVersion = "25.05";

    home.sessionPath = [
      "$HOME/bin"
    ];

    home.activation.tangleEmacsConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -f "${emacsDir}/init.el" ]; then
        echo "Tangling Emacs.org to init.el..."
        cd "${emacsDir}"
        "${emacsBin}" --batch \
          --eval "(require 'org)" \
          --eval '(progn (setq ox/enable-ivy nil ox/enable-vertico t ox/enable-cape t)
                  (org-babel-tangle-file "./Emacs.org"))'
      fi
    '';

    # Keep Neovim unmanaged by Home Manager so ~/.config/nvim/init.lua stays user-owned.
    # Neovim itself is installed from package lists in this repo.
    programs.neovim = {
      enable = false;
      extraLuaPackages = ps: [ ps.magick ];
      extraPackages = [ pkgs.imagemagick ];
    };

    programs.home-manager.enable = true;

    programs.git = {
      enable = true;
      settings.core.excludesfile = "${config.home.homeDirectory}/.gitignore_global";
    };

    programs.zsh.enable = false;

    home.packages = with pkgs; [
      ueberzugpp
      imagemagick
    ];

    programs.ranger = {
      enable = true;
      extraConfig = ''
        set preview_images true
        set preview_images_method ueberzug
      '';
    };

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    home.file = {
      ".emacs.d" = {
        source = config.lib.file.mkOutOfStoreSymlink emacsDir;
      };

      ".gitignore_global".text = ''
        .DS_Store
        .AppleDouble
        .LSOverride
        Thumbs.db
        /.agent-shell/
        Desktop.ini
        *~
        *.swp
        *.swo
        .direnv/
      '';

      ".config/ueberzugpp" = {
        source = ../ueberzugpp/.config/ueberzugpp;
      };
    };

    home.activation.decryptPassword = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.age}/bin/age --decrypt \
        -i ~/.config/sops/age/keys.txt \
        ${config.home.homeDirectory}/terminalConfigs/.dotfiles/nix/.passwordFile.age \
        > ${config.home.homeDirectory}/.passwordFile
    '';

    services = {
      syncthing = {
        enable = true;

        passwordFile = "${config.home.homeDirectory}/.passwordFile";

        overrideDevices = true;
        overrideFolders = true;

        settings = {
          options = {
            urAccepted = -1;
          };

          devices = config.rage.devices;

          gui = {
            user = config.rage.syncthingUser;
          };
        };
      };
    };
  }

  # macOS-only files/services
  (lib.mkIf isDarwin {
    home.file = {
      ".config/aerospace" = {
        source = ../aerospace/.config/aerospace;
      };
    };

    launchd.agents.removePassword = {
      # Set to true when you want it active.
      enable = false;

      config = {
        ProgramArguments = [
          "${pkgs.bash}/bin/bash"
          "-c"
          "${removePasswordScript}"
        ];

        Label = "com.yourdomain.removePassword";

        StartInterval = 10;
        RunAtLoad = true;
        KeepAlive = false;

        StandardOutPath = "/tmp/removePassword.out.log";
        StandardErrorPath = "/tmp/removePassword.err.log";
      };
    };
  })

  # Linux-only user systemd service
  (lib.mkIf isLinux {
    systemd.user.services.removePassword = {
      Unit = {
        Description = "Remove temporary Syncthing password file after Syncthing starts";
        After = [ "syncthing.service" ];
        Wants = [ "syncthing.service" ];
      };

      Service = {
        Type = "oneshot";
        ExecStart = "${removePasswordScript}";
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  })
]
