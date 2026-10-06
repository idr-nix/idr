{
  top,
  useVM,
}: {lib, ...}: {
  imports = [
    (lib.modules.importApply ./runtime-secrets-fixture.nix {
      inherit top useVM;
    })
  ];

  defaults = {
    config,
    pkgs,
    ...
  }: {
    idr.systemd.services.my-app.environment.API_TOKEN = config.idr.secrets.api-token;
    systemd.services.my-app = {
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        User = "my-app";
        Group = "my-app";
        RuntimeDirectory = "my-app";
      };
      path = [pkgs.coreutils];
      script = ''
        printf '%s' "$API_TOKEN" | sha256sum > /run/my-app/startup-token.sha256
        exec sleep infinity
      '';
      # systemd reads the updated EnvironmentFile for the reload command.
      reload = ''
        printf '%s' "$API_TOKEN" | sha256sum > /run/my-app/reloaded-token.sha256
      '';
    };
  };
}
