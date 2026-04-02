/* {inputs, ...}: {
# This one brings our custom packages from the 'pkgs' directory
additions = final: _prev: import ../pkgs {pkgs = final;};

# https://nixos.wiki/wiki/Overlays
modifications = final: prev: {
emacsLeji = import ./emacs.nix {inherit prev;};
};
} */
{inputs}:

let
  inherit (inputs) emacs-src;
in [
  (import ./emacs.nix {inherit emacs-src;})
  (final: prev:
    {
      "aider-chat" = prev."aider-chat".overrideAttrs (_old: {
        doCheck = false;
        checkPhase = "true";
        pytestCheckPhase = "true";
      });
      "yt-dlp" = prev."yt-dlp".override {
        # nixpkgs yt-dlp enables JS extraction via deno by default.
        # Disable that feature to avoid the current deno/rustc ICE on darwin.
        javascriptSupport = false;
      };
    })
]

/* {inputs}: {
  
  modifications = final: prev: {
    emacsLeji = import ./emacs.nix {inherit prev;};
  };
} */
/* {inputs}:

[
  (final: prev: {
    emacsLeji = import ./emacs.nix {inherit prev;};
  })
] */
