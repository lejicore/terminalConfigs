{
  self,
  pkgs,
  inputs,
  config,
  lib,
  ...
}:
let
  user = builtins.trace "${config.rage.username}" config.rage.username;
  homeDir = "/Users/${user}";
  configDir = "${homeDir}/.config";
  cacheDir = "${homeDir}/.cache";

  # Import the package list
  packageList = import ./packages.nix { pkgs = pkgs; };
in
{
  imports = [
    ./pam-reattach.nix
    #./postgresql.nix
  ];

  # * Nix
  # auto upgrade nix package and the daemon service

  #services.nix-daemon.enable = true;
  services.tailscale.enable = true;
   #launchd.daemons.linux-builder.environment.NIX_CONFIG = "plugin-files =";
  # launchd.daemons.linux-builder = {
  #   environment.NIX_CONFIG = "plugin-files =";

  #   serviceConfig.ProgramArguments = lib.mkForce [
  #     "/Applications/Nix Linux Builder.app/Contents/MacOS/nix-linux-builder-launcher"
  #     "/bin/sh"
  #     "-c"
  #     "/bin/wait4path /nix/store && exec ${config.launchd.daemons.linux-builder.command}"
  #   ];

  #   # Keep stock KeepAlive / RunAtLoad.
  # };

  nix-rage.nixPackage = pkgs.nixVersions.latest;
  nix = {
    linux-builder = {
      enable = true;

      package = pkgs.darwin.linux-builder-vz;
      # protocol = "ssh";

      # Keep the VZ state completely separate from QEMU.
      #workingDirectory = "/Volumes/NixBuilder/linux-builder-vz";

      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      # supportedFeatures = [
      #   #"kvm"
      #   "benchmark"
      #   "big-parallel"
      #   #"nixos-test"
      # ];

      # config = {
      #   networking.firewall.enable = false;
      #   nix.settings.ssl-cert-file =
      #     "/etc/ssl/certs/ca-certificates.crt";

      #   swapDevices = lib.mkVMOverride [
      #     {
      #       device = "/nix/.rw-store/linux-builder.swap";
      #       size = 8 * 1024;
      #     }
      #   ];

      #   virtualisation = {
      #     cores = 4;

      #     darwin-builder = {
      #       memorySize = 8 * 1024;
      #       diskSize = 96 * 1024;
      #     };

      #     vz = {
      #       nestedVirtualization = false;

      #       # Very useful during migration.
      #       console = "file";
      #       consoleLog = "./console.log";
      #     };
      #   };
      # };
    };

    package = config.nix-rage.package;
    #package = pkgs.nixVersions.nix_2_31; # for nix-rage compatibility
    settings = {
      trusted-users = [
        "root"
        "@admin"
      ];

      experimental-features = "nix-command flakes";
      download-buffer-size = 67108864;

      # Expensive custom builds that aren't available from cache.nixos.org.
      # In particular: our custom Emacs build, nix-rage, and similar packages
      # that we categorically refuse to compile twice. xD
      extra-substituters = [
        "https://lejicore.cachix.org"
      ];

      extra-trusted-public-keys = [
        "lejicore.cachix.org-1:N+R7zCu3D8Os0n65QZvOWD+4LLF2XjDvn1tsAdNyxII="
      ];

    };
    optimise.automatic = true;



    #automatically gargage collect to reduce nix store size
    gc = {
      automatic = true;
      interval = {
        Weekday = 0;
        Hour = 2;
        Minute = 0;
      };
      options = "--delete-older-than 15d";
    };

  };

  # * Environment
  environment.etc."ssh/ssh_config.d/099-linux-builder-auth.conf".text = ''
    Host linux-builder
    IdentitiesOnly yes
    IdentityAgent none
  '';

  # installing both here with home manager
  # TODO split system wise packages with home wise packages
  environment.systemPackages = packageList;

  # * Fonts
  # don't fully manage fontdir (will remove any manually installed fonts)
  # (default is false)
  #fonts.fontDir.enable = false;

  # fonts to install
  fonts.packages = [
    pkgs.cascadia-code
    pkgs.office-code-pro
    pkgs.fira-code
    pkgs.fira-mono
    pkgs.nerd-fonts.hack
    pkgs.nerd-fonts.caskaydia-cove
    pkgs.nerd-fonts.symbols-only
    pkgs.noto-fonts # base Noto; good to have
    pkgs.noto-fonts-color-emoji # color emoji coverage
    #pkgs.noto-fonts-extra # includes Symbols2 on most channels
  ];

  homebrew = {
    enable = true;
    taps = [
      "koekeishiya/formulae"
      #To install JankyBoders
      {
        name = "FelixKratz/formulae";
        trusted = true;

      }
    ];
    brews = [
      "borders"
      "sketchybar"
      "progress"
      "pam-reattach"
      "reattach-to-user-namespace"
      "libb2" # needed Because pip has blake2 errors related
      "openssl"
    ];
    casks = [
      "blackhole-2ch"
      "iterm2"
      "nikitabobko/tap/aerospace"
      "tor-browser"
      "jdownloader"
      "ungoogled-chromium"
      "docker-desktop"
      "Sikarugir-App/sikarugir/sikarugir"
    ];
    caskArgs = {
      #no_quarantine = true;
    };
  };

  # networking.firewall = {
  #   enable = true;
  # };

  # # 1. Provide a pf.conf with the desired rules
  # environment.etc."nix-pf.conf" ={
  #   text = ''
  #   scrub-anchor "com.apple/*"
  #   nat-anchor "com.apple/*"
  #   rdr-anchor "com.apple/*"
  #   dummynet-anchor "com.apple/*"
  #   anchor "com.apple/*"
  #   load anchor "com.apple" from "/etc/pf.anchors/com.apple"
  #   # e.g. allow inbound on ports 8384, 22000
  #   pass in proto tcp from any to any port 8384
  #   pass out proto tcp from any to any port 8384

  #   pass in proto tcp from any to any port 22000
  #   pass out proto tcp from any to any port 22000

  #   pass in proto udp from any to any port 22000
  #   pass out proto udp from any to any port 22000

  #   pass in proto udp from any to any port 21027
  #   pass out proto udp from any to any port 21027
  # '';
  #   mode = "0644";  # Ensure correct file permissions
  #   user = "root";
  #   group = "wheel";
  # };

  # # 2. Activation script: load pf at the end of system activation
  # system.activationScripts.postUserActivation.text = ''
  #   echo "Enabling and loading pf rules from /etc/nix-pf.conf..."
  #   /usr/bin/pfctl -e -f /etc/nix-pf.conf
  # '';
  # syncthingIsEnabled = true;
  # system.activationscripts.postUserActivation.text = ''
  #   ${if syncthingIsEnabled then ''
  #     ''}
  #   '';
  # To use TouchId for sudo operations
  security.pam.services.sudo_local.touchIdAuth = true;
  # Make TouchId for sudo operations work with tmux (see ./pam-reattach.nix)
  security.pam.enableSudoTouchIdReattach = true;

  # * System Settings
  system = {

    primaryUser = config.rage.username;
    # Set Git commit hash for darwin-version.
    configurationRevision = self.rev or self.dirtyRev or null;
    defaults = {

      # ** Appearance
      # dark mode
      NSGlobalDomain.AppleInterfaceStyle = "Dark";

      # ** Menu Bar
      NSGlobalDomain._HIHideMenuBar = false;

      # ** Dock, Mission Control
      dock = {
        autohide = true;
        # make smaller (default 64)
        tilesize = 48;
      };

      # ** Keyboard
      NSGlobalDomain.InitialKeyRepeat = 20;
      NSGlobalDomain.KeyRepeat = 1;

      # ** Mouse
      # enable tap to click
      trackpad.Clicking = true;
      NSGlobalDomain."com.apple.mouse.tapBehavior" = 1;

      # disable natural scroll direction
      NSGlobalDomain."com.apple.swipescrolldirection" = false;

      # ** Finder
      # don't show desktop icons
      finder.CreateDesktop = false;

      NSGlobalDomain.AppleShowAllExtensions = true;
      finder.AppleShowAllExtensions = true;

      # default to list view
      finder.FXPreferredViewStyle = "Nlsv";

      # full path in window title
      finder._FXShowPosixPathInTitle = true;
    };
  };

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 6;

  # The platform the configuration will be used on.
  # nixpkgs.hostPlatform = "aarch64-darwin";

  # * Users
  users.users.${user} = {
    name = user;
    home = homeDir;
  };
}
