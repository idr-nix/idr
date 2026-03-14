{
  pkgs,
  inputs,
  self,
  ...
}: let
  inherit (pkgs) lib;
  commands = import ../../../devshell/checks/commands.nix {inherit pkgs inputs self;};
  keys = import "${inputs.nixpkgs}/nixos/tests/ssh-keys.nix" pkgs;
  fixture = import ./installation/fixture.nix {
    inherit pkgs;
    disko = inputs.disko;
  };
  lockNodes = (builtins.fromJSON (builtins.readFile ../../../../flake.lock)).nodes;
  inputUrl = name: let
    original = lockNodes.${name}.original;
  in
    "git+${original.url}?shallow=1" + lib.optionalString (original ? ref) "&ref=${original.ref}";
  projectLock = pkgs.writeText "installation-flake.lock" (builtins.toJSON {
    version = 7;
    root = "root";
    nodes = {
      inherit (lockNodes) nixpkgs disko;
      root.inputs = {
        nixpkgs = "nixpkgs";
        disko = "disko";
      };
    };
  });
  project = pkgs.writeTextDir "flake.nix" ''
    {
      inputs.nixpkgs.url = "${inputUrl "nixpkgs"}";
      inputs.disko.url = "${inputUrl "disko"}";
      inputs.disko.inputs.nixpkgs.follows = "nixpkgs";
      outputs = { self, nixpkgs, disko }: let
        pkgs = nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
        machineDirectory = self + "/nix/machine/installation test";
        system = (import (machineDirectory + "/configuration.nix") {
          inherit pkgs disko;
          allowDiscards = import ./allow-discards.nix;
          hardwareReport = let path = machineDirectory + "/facter.json"; in
            if builtins.pathExists path then path else null;
        }).system;
        file = key: path: { inherit key path; sopsFile = machineDirectory + "/secrets.enc.json"; };
        meta = {
          machine = "installation-test";
          system = "${pkgs.stdenv.hostPlatform.system}";
          sshHostPublicKey = ${builtins.toJSON keys.snakeOilEd25519PublicKey};
          initrdHostPublicKey = ${builtins.toJSON keys.snakeOilEd25519PublicKey};
          initrdHostPublicKeys = [${builtins.toJSON keys.snakeOilEd25519PublicKey}];
          initrdPort = 2222;
          nixSettings = {substituters = []; trusted-public-keys = [];};
          inherit (system.config.system.build) formatMount diskoScript;
          defaultSopsFile = machineDirectory + "/secrets.enc.json";
          disko = {
            disks.system.path = "/dev/disk/by-id/virtio-installation-target";
            preFormatFiles."/disk-key.txt" = file "disk_key" "/disk-key.txt";
            postFormatFiles."/persist/fixture host key" = file "ssh_host_ed25519_key" "/persist/fixture host key";
          };
        };
      in {
        deploy = {
          sshUser = "invalid-global-user";
          sshOpts = ["-o" "ConnectTimeout=5"];
          fastConnection = false;
          nodes.production = {
            hostname = "target";
            sshUser = "invalid-node-user";
            sshOpts = ["-p" "2222"];
            profiles.system = {
              sshUser = "root";
              fastConnection = true;
              sshOpts = ["-o" ${builtins.toJSON ''SetEnv=IDR_FIRST=one "IDR_SECOND=two words"''}];
              path = system.config.system.build.toplevel // {
                idr = {inherit meta; qemuProcess = null;};
              };
            };
          };
        };
        nixosConfigurations = throw "Installation must resolve the deploy profile.";
      };
    }
  '';
  setup = pkgs.writers.writeNu "setup-installation-test" ''
    def main [] {
      mkdir $env.PRJ_ROOT $env.PRJ_DATA_DIR /root/.ssh
      cd $env.PRJ_ROOT
      cp ${project}/flake.nix flake.nix
      cp ${projectLock} flake.lock
      let machine_directory = "nix/machine/installation test"
      mkdir $machine_directory
      cp ${./installation/fixture.nix} ($machine_directory | path join "configuration.nix")
      "false" | save allow-discards.nix
      cp ${keys.snakeOilEd25519PrivateKey} /root/.ssh/id_ed25519
      chmod 0600 /root/.ssh/id_ed25519
      ssh-to-age -private-key -i /root/.ssh/id_ed25519 | save $env.SOPS_AGE_KEY_FILE
      let recipient = ${builtins.toJSON keys.snakeOilEd25519PublicKey} | ssh-to-age | str trim
      {disk_key: "test-disk-password", ssh_host_ed25519_key: (open --raw /root/.ssh/id_ed25519)}
        | to json
        | sops encrypt --age $recipient --input-type json --output-type json /dev/stdin
        | save ($machine_directory | path join "secrets.enc.json")
      ".data/\n" | save .gitignore
      git init --quiet
      git add .
      nix flake lock --offline
      git add flake.lock
      git -c user.name=Test -c user.email=test@example.invalid commit --quiet -m fixture
    }
  '';
  confirmations =
    pkgs.writers.writePython3 "installation-confirmations" {
      libraries = [pkgs.python3Packages.pexpect];
    } ''
      import pexpect

      child = pexpect.spawn(
          "idr-anywhere", ["production"], encoding="utf-8", timeout=30
      )
      child.expect_exact("Type WIPE_ALL_DISKS to continue: ")
      child.send("WIPE_ALL_DISKS\r")
      child.expect_exact("Type WIPE_NIXOS to continue: ")
      child.send("CANCEL\r")
      child.expect(pexpect.EOF)
      assert "WIPE_NIXOS was not confirmed" in child.before, child.before
      child.close()
      assert child.exitstatus != 0
    '';
in
  pkgs.testers.runNixOSTest {
    name = "idr-installation";
    globalTimeout = 15 * 60;
    meta.timeout = 20 * 60;
    defaults = {
      nix.settings = {
        sandbox = true;
        require-sigs = true;
        substituters = lib.mkForce [];
        experimental-features = ["nix-command" "flakes"];
      };
      virtualisation = {
        additionalPaths = [pkgs.stdenv pkgs.stdenvNoCC pkgs.makeWrapper];
        memorySize = 2048;
        cores = 2;
        useNixStoreImage = true;
        writableStore = true;
        writableStoreUseTmpfs = false;
        diskSize = 16384;
      };
      documentation.enable = false;
    };
    nodes = {
      controller = {
        virtualisation.additionalPaths = [
          project
          setup
          confirmations
          ./installation/cache-key
          inputs.nixpkgs
          inputs.disko
          fixture.system.config.system.build.toplevel
          fixture.system.config.system.build.diskoScript
          fixture.system.config.system.build.formatMount
        ];
        environment.systemPackages = [
          commands.packages.idr-anywhere
          commands.packages.idr-copy-extra-files
          commands.packages.ssh
          pkgs.nix
          pkgs.gitMinimal
          pkgs.nushell
          pkgs.sops
          pkgs.ssh-to-age
        ];
        programs.ssh.extraConfig = ''
          Host *
            StrictHostKeyChecking no
            UserKnownHostsFile /dev/null
        '';
      };
      target = {
        nix.settings.trusted-public-keys = [(lib.trim (builtins.readFile ./installation/cache-key.pub))];
        virtualisation.emptyDiskImages = [
          {
            size = 8192;
            driveConfig.deviceExtraOpts.serial = "installation-target";
          }
        ];
        services.openssh = {
          enable = true;
          ports = [2222];
          settings = {
            PermitRootLogin = "yes";
            PasswordAuthentication = true;
            AcceptEnv = ["IDR_FIRST" "IDR_SECOND"];
          };
        };
        users.users.root.openssh.authorizedKeys.keys = [keys.snakeOilEd25519PublicKey];
        users.users.root.initialPassword = "fixture-password";
        users.users.root.hashedPasswordFile = null;
        environment.etc."ssh/sshrc".text = ''
          printenv IDR_FIRST IDR_SECOND > /run/idr-installation-ssh-env
        '';
        environment.systemPackages = [pkgs.cryptsetup pkgs.gptfdisk pkgs.e2fsprogs pkgs.cpio pkgs.jq pkgs.nixos-facter];
      };
    };
    testScript =
      ''
        import shlex

        setup = "${setup}"
        confirmations = "${confirmations}"
        cache_key = "${./installation/cache-key}"
        expected_system = "${fixture.system.config.system.build.toplevel}"
      ''
      + builtins.readFile ./installation/test.py;
  }
