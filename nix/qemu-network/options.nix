{lib, ...}: {
  options.idr.qemu.networkPrefix = lib.mkOption {
    description = ''
      ULA /48 prefix for local QEMU networking, as fdxx:xxxx:xxxx without a prefix length.
    '';
    type = lib.types.strMatching "fd[0-9a-f]{2}(:[0-9a-f]{4}){2}";
    default = "fd3e:aacc:e60e";
  };
}
