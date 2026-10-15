{
  lib,
  deploy,
  projectConfig ? "",
  extraConfig ? "",
}: let
  hasPackagePaths = lib.any (context: context ? outputs || (context.allOutputs or false)) (
    builtins.attrValues (builtins.getContext projectConfig)
  );
  portableConfig =
    if hasPackagePaths
    then ""
    else projectConfig;
  render = projectConfig: ''
    Host *
    ${projectConfig}
    ${extraConfig}
    Host *
      Include ~/.ssh/config
      Include /etc/ssh/ssh_config
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: node: let
        sshUser = node.sshUser or (deploy.sshUser or null);
      in ''
        Host ${builtins.toJSON name}
          HostName ${builtins.toJSON node.hostname}
          ${lib.optionalString (sshUser != null) "User ${builtins.toJSON sshUser}"}
      '')
      deploy.nodes)}
  '';
in {
  inherit hasPackagePaths;
  common = builtins.toFile "idr-ssh.conf" (render portableConfig);
  text = render projectConfig;
}
