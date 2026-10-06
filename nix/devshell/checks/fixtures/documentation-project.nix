{
  project,
  isLinux,
  extraSetup ? "",
}: {lib, ...}: {
  globalTimeout = 20 * 60;

  defaults = {pkgs, ...}: {
    systemd.services.idr-project-fixture = {
      description = "Restore the generated project for documentation examples";
      wantedBy = ["multi-user.target"];
      after = ["systemd-tmpfiles-setup.service"];
      path = [pkgs.coreutils pkgs.gnutar pkgs.gitMinimal];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "operator";
        Group = "operator";
        WorkingDirectory = "/home/operator";
      };
      script = ''
        tar -xf ${project}/project.tar
        cd project
        ${extraSetup}
        git init -q
        git add -A
      '';
    };
  };

  containers = lib.optionalAttrs isLinux {machine = {};};
  nodes = lib.optionalAttrs (!isLinux) {
    machine = {
      virtualisation = {
        memorySize = 8192;
        cores = 8;
      };
      networking.useDHCP = false;
    };
  };
}
