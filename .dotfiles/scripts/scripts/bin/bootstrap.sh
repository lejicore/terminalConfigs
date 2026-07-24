#!/usr/bin/env bash

set -euo pipefail

flake_metadata="$(nix flake metadata --json .)"
# The single-quoted string is a Nix expression, not shell code.
# shellcheck disable=SC2016
NIX_RAGE_FLAKE_METADATA="$flake_metadata" \
  nix build --no-link --print-out-paths --impure --expr '
  let
    metadata = builtins.fromJSON (
      builtins.getEnv "NIX_RAGE_FLAKE_METADATA"
    );
    source = metadata.path + (
      if metadata.resolved ? dir then "/" + metadata.resolved.dir else ""
    );
    flake = builtins.getFlake ("path:" + source);
  in
  flake.inputs.nix-rage.packages.${builtins.currentSystem}.default
'
