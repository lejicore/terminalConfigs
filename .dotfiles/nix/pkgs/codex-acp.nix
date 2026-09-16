{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
}:

buildNpmPackage rec {
  pname = "codex-acp";
  version = "1.12.0";

  src = fetchFromGitHub {
    owner = "agentclientprotocol";
    repo = "codex-acp";
    rev = "v${version}";

    hash = "sha256-GIMJm+kifPEMb7XLPSssUu87eEE+aaBr2jZUk8aPD2s=";
  };

  npmDepsHash = "sha256-BeRj6LpIpGV4ONEHE//nYXTfkB1nfVQpPeJF3LRlyRM=";

  npmBuildScript = "build";

  meta = {
    description = "ACP adapter for OpenAI Codex CLI";
    homepage = "https://github.com/agentclientprotocol/codex-acp";
    license = lib.licenses.asl20;
    mainProgram = "codex-acp";
    platforms = lib.platforms.unix;
  };
}
