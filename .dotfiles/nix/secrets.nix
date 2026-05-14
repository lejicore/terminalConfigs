{
  lib,
  ...
}:
{
  # Declare the option first
  options.rage = {
    username = lib.mkOption {
      type = lib.types.str;
      description = "Username encrypted with age";
      default = "tmp";
    };
    hostName = lib.mkOption {
      type = lib.types.str;
      description = "hostName encrypted with age";
      default = "tmpHostName";
    };
    syncthingUser = lib.mkOption {
      type = lib.types.str;
      description = "Syncthing user encrypted with age";
      default = "tmpSyncthingUser";
    };

    devices = lib.mkOption {
      description = ''syncthing devices'';
      type = lib.types.submodule {
        options = {
          device1 = lib.mkOption {
            description = ''First device options'';
            type = lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.str;
                  description = "First device name";
                  default = "device1";
                };
                id = lib.mkOption {
                  type = lib.types.str;
                  description = "First device ID";
                };
                autoAcceptFolders = lib.mkOption {
                  type = lib.types.bool;
                  description = "Auto accept folders option";
                  default = "true";
                };
              };
            };
          };

          device2 = lib.mkOption {
            description = ''Second device options'';
            type = lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.str;
                  description = "Second device name";
                  default = "device2";
                };
                id = lib.mkOption {
                  type = lib.types.str;
                  description = "Second device ID";
                };
                autoAcceptFolders = lib.mkOption {
                  type = lib.types.bool;
                  description = "Auto accept folders option";
                  default = "true";
                };
              };
            };
          };
        };
      };

    };
    allowedTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "111"
        "222"
        "3333"
      ];
      description = "A list of TCP ports";
    };

    allowedTCPPortsRanges = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "111:222"
        "333:444"
        "5555:6666"
      ];
      description = "A list of TCP ranges ports";
    };

    allowedUDPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "111"
        "222"
        "3333"
      ];
      description = "A list of UDP ports";
    };

    allowedUDPPortsRanges = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "111:222"
        "333:444"
        "5555:6666"
      ];
      description = "A list of UDP ranges ports";
    };
  };

  config =
    let
      keyFile = ./secret-key;
      secrets = builtins.importAge [ keyFile ] ./secret.nix.age { cache = false; };
    in
    {
      rage = {
        username = secrets.rage-username;
        hostName = secrets.rage-hostName;
        syncthingUser = secrets.rage-syncthingUser;
        devices = secrets.rage-devices;
        allowedTCPPorts = secrets.rage-darwin-networking-allowedTCPPorts;
        allowedUDPPorts = secrets.rage-darwin-networking-allowedUDPPorts;
        allowedTCPPortsRanges = secrets.rage-darwin-networking-allowedTCPPortsRanges;
        allowedUDPPortsRanges = secrets.rage-darwin-networking-allowedUDPPortsRanges;
      };
    };
}
