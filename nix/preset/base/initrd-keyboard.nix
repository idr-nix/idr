_: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.boot.initrd.unl0kr;
in {
  config = lib.mkIf (config.idr.preset.base.enable && !config.boot.isContainer) (lib.mkMerge [
    {
      boot.initrd.unl0kr.enable = lib.mkDefault (
        config.boot.initrd.enable && config.boot.initrd.systemd.enable && !config.boot.plymouth.enable
      );
    }
    (lib.mkIf cfg.enable {
      boot.initrd.unl0kr.settings = {
        general.backend = lib.mkDefault "fbdev";
        keyboard.autohide = lib.mkDefault false;
        "hardware keyboard" = lib.mapAttrs (_: lib.mkDefault) {
          inherit (config.services.xserver.xkb) model layout variant options;
        };
      };

      # Avoid failed graphical agents when no display device is present.
      boot.initrd.systemd.paths.unl0kr-agent = {
        wantedBy = lib.mkForce [];
        after = ["systemd-modules-load.service"];
      };
      boot.initrd.systemd.storePaths = [
        "${pkgs.kbd}/bin/openvt"
        "${pkgs.kbd}/bin/chvt"
      ];
      # Console password queries reset their terminal to text mode; give the UI its own VT.
      boot.initrd.systemd.services.unl0kr-agent = {
        preStart = ''
          read -r previousVT < /sys/class/tty/tty0/active
          printf '%s\n' "$previousVT" > /run/unl0kr/previous-vt
        '';
        postStop = ''
          if read -r previousVT < /run/unl0kr/previous-vt; then
            ${pkgs.kbd}/bin/chvt "''${previousVT#tty}"
          fi
          # The console agent may have selected the UI's VT while it was active.
          if [ "$SERVICE_RESULT" != success ]; then
            ${config.boot.initrd.systemd.package}/bin/systemctl --no-block restart systemd-ask-password-console.service
          fi
        '';
        serviceConfig = {
          RuntimeDirectory = "unl0kr";
          ExecStart = [
            ""
            "${pkgs.kbd}/bin/openvt --switch --exec -- ${cfg.package}/libexec/unl0kr-agent"
          ];
        };
      };
      boot.initrd.services.udev.rules =
        if cfg.settings.general.backend == "drm"
        then ''
          ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="unl0kr-agent.path"
        ''
        else ''
          ACTION=="add", SUBSYSTEM=="graphics", KERNEL=="fb0", TAG+="systemd", ENV{SYSTEMD_WANTS}+="unl0kr-agent.path"
        '';
    })
    (lib.mkIf (cfg.enable && config.services.iptsd.enable) {
      boot.initrd.kernelModules = ["uinput"];
      boot.initrd.services.udev.packages = [pkgs.iptsd];
      boot.initrd.systemd = {
        packages = [pkgs.iptsd];
        storePaths = [
          "${pkgs.iptsd}/bin/iptsd"
          "${pkgs.iptsd}/bin/iptsd-check-device"
          "${pkgs.iptsd}/share/iptsd"
          "${pkgs.systemd}/bin/systemd-escape"
        ];
        contents."/etc/iptsd.conf".source = config.environment.etc."iptsd.conf".source;
        services."iptsd@" = {
          unitConfig.DefaultDependencies = false;
          after = ["systemd-modules-load.service"];
          before = ["initrd-switch-root.target" "shutdown.target"];
          conflicts = ["initrd-switch-root.target" "shutdown.target"];
        };
      };
    })
  ]);
}
