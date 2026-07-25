#!/usr/bin/env bash

set -euo pipefail

# Nix 2.35 can keep a Git flake behind a lazy source accessor.  The path
# reported by `nix flake metadata` then names the eventual store path even
# when that path has not been materialized yet.  `builtins.getFlake "path:…"`
# needs a physical path, so archive the staged source before using it.
nix flake archive --no-write-lock-file --json . >/dev/null

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
