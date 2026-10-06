{
  lib,
  stdenv,
  OVMF,
}:
if stdenv.hostPlatform.isAarch64
then
  (OVMF.overrideAttrs (old: {
    # EDK's module parallelism leaves large libraries such as OpenSSL serial.
    # Build one module at a time and share the allocated cores within its make.
    buildPhase = assert lib.hasInfix "-n $NIX_BUILD_CORES" old.buildPhase;
      lib.replaceStrings ["-n $NIX_BUILD_CORES"] ["-n 1"] old.buildPhase;
    preBuild =
      (old.preBuild or "")
      + ''
        export MAKEFLAGS="''${MAKEFLAGS:+$MAKEFLAGS }-j$NIX_BUILD_CORES"
      '';

    # ArmVirt omits the ATA drivers needed to boot disks on our AHCI controller.
    postPatch =
      (old.postPatch or "")
      + ''
        substituteInPlace ArmVirtPkg/ArmVirtQemu.dsc --replace-fail \
          '  MdeModulePkg/Bus/Pci/NvmExpressDxe/NvmExpressDxe.inf' \
          '  MdeModulePkg/Bus/Pci/NvmExpressDxe/NvmExpressDxe.inf
          MdeModulePkg/Bus/Pci/SataControllerDxe/SataControllerDxe.inf
          MdeModulePkg/Bus/Ata/AtaAtapiPassThru/AtaAtapiPassThru.inf
          MdeModulePkg/Bus/Ata/AtaBusDxe/AtaBusDxe.inf'
        substituteInPlace ArmVirtPkg/ArmVirtQemuFvMain.fdf.inc --replace-fail \
          '  INF MdeModulePkg/Bus/Pci/NvmExpressDxe/NvmExpressDxe.inf' \
          '  INF MdeModulePkg/Bus/Pci/NvmExpressDxe/NvmExpressDxe.inf
          INF MdeModulePkg/Bus/Pci/SataControllerDxe/SataControllerDxe.inf
          INF MdeModulePkg/Bus/Ata/AtaAtapiPassThru/AtaAtapiPassThru.inf
          INF MdeModulePkg/Bus/Ata/AtaBusDxe/AtaBusDxe.inf'
      '';
  }))
  .fd
else OVMF.fd
