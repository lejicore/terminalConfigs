{
  self,
  pkgs,
  inputs,
  config,
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
  ];

  # * Nix
  # auto upgrade nix package and the daemon service

  #services.nix-daemon.enable = true;
  nix = {
    package = pkgs.nixVersions.latest;
    #package = pkgs.nixVersions.nix_2_24;
    settings.trusted-users = [
      "root"
      "@admin"
    ];

    settings.experimental-features = "nix-command flakes";
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
    pkgs.noto-fonts-emoji # color emoji coverage
    pkgs.noto-fonts-extra # includes Symbols2 on most channels
  ];

  homebrew = {
    enable = true;
    taps = [
      "koekeishiya/formulae"
      #To install JankyBoders
      "FelixKratz/formulae"
      "mhaeuser/mhaeuser"
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
      "iterm2"
      "nikitabobko/tap/aerospace"
      "tor-browser"
      "jdownloader"
      "ungoogled-chromium"
      "battery-toolkit"
    ];
    caskArgs = {
      no_quarantine = true;
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
      NSGlobalDomain._HIHideMenuBar = true;

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
