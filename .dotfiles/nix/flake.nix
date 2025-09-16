{
  description = "Nix configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:LnL7/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mac-app-util.url = "github:hraban/mac-app-util";
    sops-nix.url = "github:Mic92/sops-nix";
    nix-rage = {
      url = "github:renesat/nix-rage";
      #url = "github:S0mbr3/nix-rage?ref=fix_missing_headers";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # https://nixos.wiki/wiki/Emacs
    # https://nixos.wiki/wiki/Overlays#In_a_Nix_flake
    emacs-overlay = {
      url = "github:nix-community/emacs-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # To get a pinned version for the emacs overlay
    # Updating emacs is now:  nix flake lock --update-input emacs-src
    emacs-src = {
      #url    = "git+https://git.savannah.gnu.org/git/emacs.git?rev=dd5ae0f3ba56e762ae1265b0cb0fe9f2a28281ec";
      #url = "github:emacs-mirror/emacs?rev=dd5ae0f3ba56e762ae1265b0cb0fe9f2a28281ec"; # <- 30 April 2025
      #url = "github:emacs-mirror/emacs?rev=d3d93bc3825e7ee4319330f81c59ae249eba2e25"; # <- 23 August 2025
      url = "github:emacs-mirror/emacs?rev=680ef7b5f0bdc1c215a66e165851a07177db7ed0"; # <- 21 August 2025

      flake = false; # it is *not* a flake
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, home-manager, nix-darwin, nixpkgs, mac-app-util, emacs-overlay, nix-rage, sops-nix, rust-overlay, emacs-src}:
    let
      pkg-config = {
        allowUnfree = true;
        allowBroken = true;
        allowInsecure = false;
      };
      common-overlays =
        [
          # default emacs-overlay (overriden by ./overlays/emacs.nix)
          (import emacs-overlay)
	  (import rust-overlay)
        ] ++ import ./overlays {inherit inputs;};
      darwin-pkgs = import nixpkgs {
        # M1
        system = "aarch64-darwin";
        config = pkg-config;
        overlays = common-overlays;
      };
      # We import our separate "sops.nix" module, which defines the secret "user"
      sopsModule = import ./sops.nix {inherit inputs;};
      secrets = import ./secrets.nix {
	inherit (darwin-pkgs) lib config;
	inherit pkg-config;} ;
      rage-username = secrets.config.rage-username;
      rage-hostName = secrets.config.rage-hostName;

      # This module references config.sops.secrets.user.contents 
      # and sets up home-manager.users."<secret>"
    in
      {
	# NixOS system-wide home-manager configuration
	home-manager.sharedModules = [
	  inputs.sops-nix.homeManagerModules.sops
	  secrets
	];
	# $ darwin-rebuild switch .
	darwinConfigurations.default = nix-darwin.lib.darwinSystem {
          pkgs = darwin-pkgs;
          system = "aarch64-darwin";
          modules = [
	    # First load sops so the secrets are available
	    sops-nix.darwinModules.sops
	    sopsModule
            mac-app-util.darwinModules.default
            home-manager.darwinModules.home-manager {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users."${rage-username}" = import ./home.nix;

            }
            ./darwin
          ];
          specialArgs = { inherit self inputs; };
	};
	darwinConfigurations."Personal-Darwin-Air" = nix-darwin.lib.darwinSystem {
          pkgs = darwin-pkgs;
          system = "aarch64-darwin";
          modules = [
	    {
              nix.extraOptions = let
		nix-rage-package = nix-rage.packages."aarch64-darwin".default;
              in ''
		plugin-files = ${nix-rage-package}/lib/libnix_rage.dylib
              '';
            }
	    {networking.hostName = rage-hostName;}
	    ./secrets.nix
            mac-app-util.darwinModules.default
            home-manager.darwinModules.home-manager {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
	      home-manager.backupFileExtension = "Backup";
	      home-manager.users.${rage-username}.imports = [ ./home.nix secrets ];
            }
            ./darwin
          ];
          specialArgs = { inherit self inputs; };
	};
	# Build darwin flake using:
	# $ darwin-rebuild build --flake .#simple
	darwinConfigurations."simple" = nix-darwin.lib.darwinSystem {
          pkgs = darwin-pkgs;
          system = "aarch64-darwin";
          modules = [
            ./darwin
            { nixpkgs.overlays = import ./overlays; }
          ];
	};
	# Build home-manager flake using:
	# home-manager switch --flake .#user
	homeConfigurations.${rage-username} = home-manager.lib.homeManagerConfiguration {
	  pkgs = darwin-pkgs; # Match your system architecture
	  modules = [ 
	    ./home.nix 
	    ./secrets.nix
	  ];
	  extraSpecialArgs = { inherit inputs self; };
	};
      };
}
