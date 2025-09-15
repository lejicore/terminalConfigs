{ pkgs }:
with pkgs;
let
  common-packages = import ../common/packages.nix { pkgs = pkgs; };
in

common-packages
++ [
  wget
  gnugrep
  tree
  # needed for Emacs to use --dired in ls commands
  coreutils
]
