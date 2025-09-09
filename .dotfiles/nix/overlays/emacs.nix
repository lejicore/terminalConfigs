# my custom Emacs
# use emacs-plus patches on osx
# (eventually) use lucid on linux

# relevant links:
# https://github.com/NixOS/nixpkgs/blob/master/pkgs/applications/editors/emacs/generic.nix
# https://github.com/nix-community/emacs-overlay/blob/master/overlays/emacs.nix
# https://github.com/d12frosted/homebrew-emacs-plus/tree/master/patches/emacs-30
# {prev}:
{ emacs-src }:
final: prev:

let
  inherit (emacs-src) outPath rev; # flake inputs expose these
  shortRev = builtins.substring 0 7 rev;
in
rec {
  # configuration shared for all systems
  # To build on specific Emacs version use EG: (prev.emacs31.ovveride {
  # Else it build uppon the emacs-git overlay declared in the flake.nix using Emacs master branch
  emacsGitLejiGeneric =
    (prev.emacs-git.override {
      # emacsGitLejiGeneric = (prev.emacs29.override {
      withSQLite3 = true;
      withWebP = true;
      withImageMagick = true;
      withTreeSitter = true;
      withMailutils = true;
      withNativeCompilation = true;
    }).overrideAttrs
      (oldAttrs: {
        src = emacs-src; # ← pin the tree
        version = "${oldAttrs.version}-${shortRev}";
        env = (oldAttrs.env or { }) // {
          NIX_CFLAGS_COMPILE = (oldAttrs.env.NIX_CFLAGS_COMPILE or "") + " -O2 -march=native -mtune=native";
        };
        makeFlags = (oldAttrs.makeFlags or [ ]) ++ [ "NATIVE_FULL_AOT=1" ];
      });
  emacsLeji =
    if prev.stdenv.isDarwin then
      emacsGitLejiGeneric.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          # Fix OS window role so that yabai can pick up Emacs
          # (prev.fetchpatch {
          #   url = "https://raw.githubusercontent.com/d12frosted/homebrew-emacs-plus/master/patches/emacs-28/fix-window-role.patch";
          #   sha256 = "+z/KfsBm1lvZTZNiMbxzXQGRTjkCFO4QPlEK35upjsE=";
          # })
          # Add setting to enable rounded window with no decoration (still
          # have to alter default-frame-alist)
          (prev.fetchpatch {
            url = "https://raw.githubusercontent.com/d12frosted/homebrew-emacs-plus/master/patches/emacs-31/round-undecorated-frame.patch";
            sha256 = "WWLg7xUqSa656JnzyUJTfxqyYB/4MCAiiiZUjMOqjuY=";
          })
          /*
            # Fix alpha-background not working on macOS NS build
            (prev.fetchpatch {
              url = "https://raw.githubusercontent.com/jimeh/build-emacs-for-macos/master/patches/emacs-29/ns-alpha-background.patch";
              sha256 = "jdWAXzqJrdUHE/AtE2rnWKQpOdHM7I9ZhScdMeL/y6k=";
            })
          */
          # Same but for Emacs 31
          (prev.fetchpatch {
            url = "https://raw.githubusercontent.com/bbenchen/homebrew-emacs-plus/master/patches/emacs-31/alpha-background.patch";
            # sha256 = "10d62i3kr4ld5idiklzh3fv0rfc31pf8p0f9dbkavj30vzpzqz9v";
            #sha256 = "aozFcD8Vo3/4/VfZdqPPCWdsBvBQicPPYzoozGxKVOk=";
            sha256 = "qfZhWue2RgwEbiz64nKL0Nq5/loMGhg5oDK+gCNyHOg=";
          })

          # Modified patch to enable alpha-background on Emacs 31
          #./aplha-background.patch

          # Add blur need the aplha-background patch to work
          (prev.fetchpatch {
            url = "https://raw.githubusercontent.com/bbenchen/homebrew-emacs-plus/master/patches/emacs-30/blur.patch";
            # sha256 = "10d62i3kr4ld5idiklzh3fv0rfc31pf8p0f9dbkavj30vzpzqz9v";
            sha256 = "X6ml5Gr5vUaQSb38H92lhK8X9D6oDL4bzmO1ujS74ws=";
          })
          # Make Emacs aware of OS-level light/dark mode
          # https://github.com/d12frosted/homebrew-emacs-plus#system-appearance-change
          (prev.fetchpatch {
            url = "https://raw.githubusercontent.com/d12frosted/homebrew-emacs-plus/master/patches/emacs-31/system-appearance.patch";
            sha256 = "4+2U+4+2tpuaThNJfZOjy1JPnneGcsoge9r+WpgNDko=";
          })

        ];
        withNS = true;
      })
    else
      (emacsGitLejiGeneric.override {
        withX = true;
        withGTK3 = true;
        withDbus = true;
      });
  emacsLejiWithPackages = (
    (prev.emacsPackagesFor emacsLeji).emacsWithPackages (epkgs: [
      # necessary to install through nix to get libenchant integration working
      epkgs.jinx
      # not needed on linux but needed on mac
      epkgs.vterm
      epkgs.treesit-grammars.with-all-grammars
      epkgs.gcmh
      # epkgs.all-the-icons
    ])
  );

  # for Wayland builds
  emacsLejiWayland = (
    emacsGitLejiGeneric.override {
      withX = false;
      withPgtk = true;
    }
  );
  emacsPgtkWithPackages = (
    (prev.emacsPackagesFor emacsLejiWayland).emacsWithPackages (epkgs: [
      # necessary to install through nix to get libenchant integration working
      epkgs.jinx
      # not needed but prevents need to compile on first run
      epkgs.vterm
      epkgs.treesit-grammars.with-all-grammars
      epkgs.gcmh
    ])
  );
}
