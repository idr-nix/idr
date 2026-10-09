{
  top,
  project,
  system,
  cachedImages ? true,
  restoreProject ? true,
  useBackingImages ? false,
}: let
  networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
in
  {
    hostPkgs,
    lib,
    ...
  }: let
    projectDirectory =
      if hostPkgs.stdenv.hostPlatform.isDarwin
      then "/run/idr-project-archive"
      else toString project;
  in {
    imports = [(lib.modules.importApply ./nested-qemu-fixture.nix {})] ++ (with top.self.modules.nixosTest; [base]);

    globalTimeout = 30 * 60;
    requiredFeatures.devnet = hostPkgs.stdenv.hostPlatform.isLinux;

    idr.test.storePaths = [top.self.packages.${system}.default];

    containerDefaults.virtualisation.systemd-nspawn.options = [
      "--bind=/dev/net/tun"
      "--capability=CAP_NET_ADMIN"
    ];
    nodeDefaults = {
      boot.kernelModules = ["tun"];
      # The archive is one file, so Darwin's filename case handling cannot alter
      # its contents. Share it separately instead of copying multi-GB VM images
      # into every guest's EROFS store image before unpacking them again.
      virtualisation = lib.mkIf hostPkgs.stdenv.hostPlatform.isDarwin {
        sharedDirectories.project-archive = {
          source = toString project;
          target = projectDirectory;
          securityModel = "none";
        };
        fileSystems.${projectDirectory}.options = ["ro"];
      };
    };

    defaults = {pkgs, ...}: {
      imports = [top.self.modules.nixos.qemu-host];
      idr = {
        qemu-host.enable = true;
        qemu.networkPrefix = networkPrefix;
      };
      networking.useHostResolvConf = false;
      programs.git = {
        enable = true;
        config.user = {
          name = "Fixture";
          email = "fixture@example.invalid";
        };
      };
      programs.ssh = {
        systemd-ssh-proxy.enable = false;
        extraConfig = ''
          Host vm-*
            StrictHostKeyChecking accept-new
            BatchMode yes
            ConnectTimeout 10
        '';
      };
      environment = {
        systemPackages = [pkgs.jq];
        etc."ssh/ssh_config".mode = "0644";
      };

      # The build sandbox cannot elevate a regular user through a setuid bridge helper.
      systemd.services.idr-project-fixture = {
        description = "Restore the project and cached VM images";
        wantedBy = ["multi-user.target"];
        after = ["systemd-tmpfiles-setup.service"];
        path = [pkgs.coreutils pkgs.gnutar pkgs.gitMinimal] ++ lib.optional useBackingImages pkgs.qemu;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          WorkingDirectory = "/root";
        };
        script = ''
          ${lib.optionalString restoreProject ''
            tar --no-same-owner -xf ${projectDirectory}/project.tar
          ''}
          ${lib.optionalString cachedImages ''
            image_cache="project/.data/$(cat /etc/machine-id)/test-machine"
            mkdir -p "$image_cache" project/.data/image-references
            ${
              if useBackingImages
              then ''
                mkdir -p "$image_cache/qemu"
                for image in ${projectDirectory}/images/*.qcow2; do
                  qemu-img create -f qcow2 -F qcow2 -b "$image" "$image_cache/qemu/$(basename "$image")"
                done
              ''
              else ''
                mv project/.data/images "$image_cache/qemu"
              ''
            }
            for image in "$image_cache/qemu"/*.qcow2; do
              ln "$image" project/.data/image-references/
            done
          ''}
          ${lib.optionalString restoreProject ''
            git -C project init -q
            git -C project add -A
          ''}
        '';
      };
    };
  }
