/*
  {inputs, ...}: {
  # This one brings our custom packages from the 'pkgs' directory
  additions = final: _prev: import ../pkgs {pkgs = final;};

  # https://nixos.wiki/wiki/Overlays
  modifications = final: prev: {
  emacsLeji = import ./emacs.nix {inherit prev;};
  };
  }
*/
{ inputs }:

let
  inherit (inputs) emacs-src;
in
[
  (import ./emacs.nix { inherit emacs-src; })
  # Darwin fixes for aider-achat and direnv, test to remove them later
  (
    final: prev:
    prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
      "aider-chat" = prev."aider-chat".overrideAttrs (_old: {
        doCheck = false;
        checkPhase = "true";
        pytestCheckPhase = "true";
      });
      "yt-dlp" = prev."yt-dlp".override {
        # nixpkgs yt-dlp enables JS extraction via deno by default.
        # Disable that feature to avoid the current deno/rustc ICE on darwin.
        javascriptSupport = true;
      };
      "shtab" = prev.python3Packages.shtab.overrideAttrs (_: {
        doCheck = false;
      });
      chromaprint = prev.chromaprint.overrideAttrs (_: {
        doCheck = false;
      });
      kvazaar = prev.kvazaar.overrideAttrs (_: {
        doCheck = false;
      });
      libcdio-paranoia = prev.libcdio-paranoia.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace src/getopt.h \
            --replace 'extern int getopt ();' '/* extern int getopt (); */'
        '';
      });
      direnv = prev.direnv.overrideAttrs (_: {
        doCheck = false;
      });
    }
  )
]

/*
  {inputs}: {

    modifications = final: prev: {
      emacsLeji = import ./emacs.nix {inherit prev;};
    };
  }
*/
/*
  {inputs}:

  [
    (final: prev: {
      emacsLeji = import ./emacs.nix {inherit prev;};
    })
  ]
*/
