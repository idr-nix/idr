{
  lib,
  diskDevices,
}: let
  rawDisks =
    lib.mapAttrs (diskName: diskCfg: let
      pathParts = lib.splitString "/" diskCfg.device;
      fileName = lib.last pathParts;
      deviceType =
        if lib.hasPrefix "/dev/disk/by-" diskCfg.device
        then lib.removePrefix "by-" (builtins.elemAt pathParts 3)
        else null;
      isPartitionId = deviceType == "id" && builtins.match ".*-part[0-9]+" fileName != null;
      transport =
        if deviceType == "id"
        then lib.head (lib.splitString "-" fileName)
        else null;
      ataMatch = builtins.match "ata-([A-Za-z0-9._-]{1,40})_([A-Za-z0-9._-]{1,20})" fileName;
      nvmeEuiMatch = builtins.match "nvme-eui\\.([0-9a-f]{16})" fileName;
      nvmeNguidMatch = builtins.match "nvme-eui\\.([0-9a-f]{32})" fileName;
      nvmeSerialMatch = builtins.match "nvme-QEMU_NVMe_Ctrl_([A-Za-z0-9._-]{1,20})" fileName;
      scsiMatch = builtins.match "scsi-0QEMU_QEMU_HARDDISK_([A-Za-z0-9._-]{1,20})" fileName;
      scsiWwnMatch = builtins.match "scsi-3([0-9a-f]{16})" fileName;
      virtioMatch = builtins.match "virtio-([A-Za-z0-9._-]{1,20})" fileName;
      wwnMatch = builtins.match "wwn-(0x[0-9a-f]{16})" fileName;
      directNvmeMatch = builtins.match "/dev/nvme[0-9]+n1" diskCfg.device;
      directScsiMatch = builtins.match "/dev/sd[a-z]" diskCfg.device;
      directVirtioMatch = builtins.match "/dev/vd[a-z]" diskCfg.device;
      ataModel =
        if ataMatch != null
        then builtins.head ataMatch
        else null;
      ataSerial =
        if ataMatch != null
        then builtins.elemAt ataMatch 1
        else null;
      nvmeEui =
        if nvmeEuiMatch != null && builtins.head nvmeEuiMatch != "0000000000000000"
        then builtins.head nvmeEuiMatch
        else null;
      nvmeNguid =
        if nvmeNguidMatch != null && builtins.head nvmeNguidMatch != "00000000000000000000000000000000"
        then builtins.head nvmeNguidMatch
        else null;
      nvmeSerial =
        if nvmeSerialMatch != null
        then builtins.head nvmeSerialMatch
        else null;
      scsiSerial =
        if scsiMatch != null
        then builtins.head scsiMatch
        else null;
      scsiWwn =
        if scsiWwnMatch != null && builtins.head scsiWwnMatch != "0000000000000000"
        then "0x${builtins.head scsiWwnMatch}"
        else null;
      virtioSerial =
        if virtioMatch != null
        then builtins.head virtioMatch
        else null;
      wwn =
        if wwnMatch != null && builtins.head wwnMatch != "0x0000000000000000"
        then builtins.head wwnMatch
        else null;
      qemuType =
        if deviceType != "id"
        then
          if directNvmeMatch != null
          then "nvme-direct"
          else if directScsiMatch != null
          then "scsi-direct"
          else if directVirtioMatch != null
          then "virtio-direct"
          else null
        else if isPartitionId
        then null
        else if ataSerial != null
        then "ata"
        else if nvmeEui != null
        then "nvme-eui"
        else if nvmeNguid != null
        then "nvme-nguid"
        else if nvmeSerial != null
        then "nvme-serial"
        else if scsiSerial != null
        then "scsi"
        else if scsiWwn != null
        then "scsi-wwn"
        else if virtioSerial != null
        then "virtio"
        else if wwn != null
        then "wwn"
        else null;
      qemuIdentifier =
        if qemuType == "ata"
        then ataSerial
        else if qemuType == "nvme-eui"
        then nvmeEui
        else if qemuType == "nvme-nguid"
        then nvmeNguid
        else if qemuType == "nvme-serial"
        then nvmeSerial
        else if qemuType == "scsi"
        then scsiSerial
        else if qemuType == "scsi-wwn"
        then scsiWwn
        else if qemuType == "virtio"
        then virtioSerial
        else if qemuType == "wwn"
        then wwn
        else if builtins.elem qemuType ["nvme-direct" "scsi-direct" "virtio-direct"]
        then fileName
        else null;
      qemuBus =
        if builtins.elem qemuType ["nvme-direct" "nvme-eui" "nvme-nguid" "nvme-serial"]
        then "nvme"
        else if builtins.elem qemuType ["scsi" "scsi-direct" "scsi-wwn" "wwn"]
        then "scsi"
        else if builtins.elem qemuType ["virtio" "virtio-direct"]
        then "virtio"
        else if qemuType == "ata"
        then "ata"
        else null;
    in {
      inherit (diskCfg) imageName name;
      path = diskCfg.device;
      device = fileName;
      size = diskCfg.imageSize;
      type = deviceType;
      inherit transport;
      qemu = {
        type = qemuType;
        identifier = qemuIdentifier;
        model =
          if qemuType == "ata"
          then ataModel
          else null;
        bus = qemuBus;
      };
    })
    diskDevices;
  diskNames = builtins.attrNames rawDisks;
  busIndexes = lib.genAttrs ["ata" "nvme" "scsi" "virtio"] (
    bus:
      lib.listToAttrs (lib.imap0 (
          index: diskName: lib.nameValuePair diskName index
        )
        (lib.filter (diskName: rawDisks.${diskName}.qemu.bus == bus) diskNames))
  );
  hasAta = builtins.length (builtins.attrNames busIndexes.ata) > 0;
  nvmeDiskCount = builtins.length (builtins.attrNames busIndexes.nvme);
  deviceLetters = lib.stringToCharacters "abcdefghijklmnopqrstuvwxyz";
  directTypes = ["nvme-direct" "scsi-direct" "virtio-direct"];
  disks = lib.mapAttrs (diskName: disk: let
    qemuType = disk.qemu.type;
    isPartitionId = disk.type == "id" && builtins.match ".*-part[0-9]+" disk.device != null;
    busIndex =
      if disk.qemu.bus == null
      then null
      else busIndexes.${disk.qemu.bus}.${diskName};
    deviceLetter =
      if busIndex != null && busIndex < builtins.length deviceLetters
      then builtins.elemAt deviceLetters busIndex
      else null;
    expectedPath =
      if qemuType == "nvme-direct"
      then "/dev/nvme${toString busIndex}n1"
      else if qemuType == "scsi-direct" && deviceLetter != null
      then "/dev/sd${deviceLetter}"
      else if qemuType == "virtio-direct" && deviceLetter != null
      then "/dev/vd${deviceLetter}"
      else null;
    supported =
      if qemuType == null
      then false
      else if qemuType == "ata"
      then busIndex < 4
      else if disk.qemu.bus == "scsi" && busIndex >= 256
      then false
      else if qemuType == "nvme-direct"
      then nvmeDiskCount == 1 && disk.path == "/dev/nvme0n1"
      else if builtins.elem qemuType directTypes
      then expectedPath != null && expectedPath == disk.path && !(qemuType == "scsi-direct" && hasAta)
      else true;
    reason =
      if isPartitionId
      then "partition symlinks cannot identify whole-disk QEMU images"
      else if qemuType == null
      then "the disk identity cannot be reproduced by the QEMU runner"
      else if qemuType == "ata" && busIndex >= 4
      then "QEMU's built-in IDE controller supports at most four ATA disks"
      else if disk.qemu.bus == "scsi" && busIndex >= 256
      then "QEMU's SCSI controller supports at most 256 disks"
      else if qemuType == "scsi-direct" && hasAta
      then "direct /dev/sd* names are not deterministic when ATA disks are also present"
      else if qemuType == "nvme-direct" && nvmeDiskCount != 1
      then "direct NVMe controller numbers are not deterministic with multiple NVMe disks"
      else if builtins.elem qemuType directTypes && expectedPath == null
      then "the QEMU runner supports at most 26 direct disks on this bus"
      else if builtins.elem qemuType directTypes && expectedPath != disk.path
      then "QEMU would expose this disk as ${expectedPath}"
      else null;
    qemuSerial =
      if builtins.elem qemuType ["ata" "nvme-serial" "scsi" "virtio"]
      then disk.qemu.identifier
      else if qemuType == "nvme-eui"
      then "idr:eui:${toString busIndex}"
      else if qemuType == "nvme-nguid"
      then "idr:nguid:${toString busIndex}"
      else if qemuType == "nvme-direct"
      then "idr:nvme:${toString busIndex}"
      else if qemuType == "scsi-direct"
      then "idr:scsi:${toString busIndex}"
      else if qemuType == "virtio-direct"
      then "idr:virtio:${toString busIndex}"
      else null;
  in
    disk
    // {
      qemu =
        disk.qemu
        // {
          inherit busIndex expectedPath reason supported;
          serial = qemuSerial;
        };
    })
  rawDisks;
  needsScsiBus = lib.any (disk: disk.qemu.bus == "scsi") (builtins.attrValues disks);
  diskQemuArgs = lib.imap0 (
    idx: diskName: let
      disk = disks.${diskName};
      driveId = "drive-${toString idx}";
      nvmeId = "nvme-${toString idx}";
      bootIndex = "bootindex=${toString (idx + 1)}";
      imageName = lib.replaceStrings [","] [",,"] disk.imageName;
      # Linux prefers a nonzero namespace UUID over the NGUID for its by-id path.
      nvmeNamespaceId =
        if disk.qemu.type == "nvme-nguid"
        then "nguid=${disk.qemu.identifier},uuid=00000000-0000-0000-0000-000000000000"
        else "eui64=0x${disk.qemu.identifier}";
      scsiAddress = "bus=scsi0.0,channel=0,scsi-id=${toString disk.qemu.busIndex},lun=0";
      ideBus =
        if disk.qemu.type == "ata"
        then builtins.div disk.qemu.busIndex 2
        else null;
      ideUnit =
        if disk.qemu.type == "ata"
        then disk.qemu.busIndex - (ideBus * 2)
        else null;
    in
      # Namespace boot indices publish an invalid firmware path in QEMU; use the controller.
      if builtins.elem disk.qemu.type ["nvme-eui" "nvme-nguid"]
      then [
        "-drive"
        "file=${imageName}.qcow2,format=qcow2,if=none,id=${driveId}"
        "-device"
        "nvme,id=${nvmeId},serial=${disk.qemu.serial},${bootIndex}"
        "-device"
        "nvme-ns,bus=${nvmeId},nsid=1,${nvmeNamespaceId},drive=${driveId}"
      ]
      else if builtins.elem disk.qemu.type ["nvme-direct" "nvme-serial"]
      then [
        "-drive"
        "file=${imageName}.qcow2,format=qcow2,if=none,id=${driveId}"
        "-device"
        "nvme,id=${nvmeId},serial=${disk.qemu.serial},${bootIndex}"
        "-device"
        "nvme-ns,bus=${nvmeId},nsid=1,drive=${driveId}"
      ]
      else if builtins.elem disk.qemu.type ["virtio" "virtio-direct"]
      then [
        "-drive"
        "file=${imageName}.qcow2,format=qcow2,if=none,id=${driveId}"
        "-device"
        "virtio-blk-pci,serial=${disk.qemu.serial},drive=${driveId},${bootIndex}"
      ]
      else if builtins.elem disk.qemu.type ["scsi-wwn" "wwn"]
      then [
        "-drive"
        "file=${imageName}.qcow2,format=qcow2,if=none,id=${driveId}"
        "-device"
        "scsi-hd,${scsiAddress},wwn=${disk.qemu.identifier},drive=${driveId},${bootIndex}"
      ]
      else if builtins.elem disk.qemu.type ["scsi" "scsi-direct"]
      then [
        "-drive"
        "file=${imageName}.qcow2,format=qcow2,if=none,id=${driveId}"
        "-device"
        "scsi-hd,${scsiAddress},serial=${disk.qemu.serial},drive=${driveId},${bootIndex}"
      ]
      else if disk.qemu.type == "ata"
      then [
        "-drive"
        "file=${imageName}.qcow2,format=qcow2,if=none,id=${driveId}"
        "-device"
        "ide-hd,bus=ide.${toString ideBus},unit=${toString ideUnit},model=${disk.qemu.model},serial=${disk.qemu.identifier},drive=${driveId},${bootIndex}"
      ]
      else [
        "-drive"
        "file=${imageName}.qcow2,format=qcow2,if=virtio,id=${driveId}"
      ]
  ) (builtins.attrNames diskDevices);
in {
  inherit disks;
  qemuUdevRules = lib.concatMapStringsSep "\n" (
    disk:
      lib.optionalString (disk.qemu.type == "nvme-eui") ''
        SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="nvme*[0-9]n*[0-9]", ATTRS{model}=="QEMU NVMe Ctrl", ATTRS{serial}=="${disk.qemu.serial}", SYMLINK+="disk/by-id/nvme-eui.${disk.qemu.identifier}"
        SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", KERNEL=="nvme*[0-9]n*[0-9]p*[0-9]", ATTRS{model}=="QEMU NVMe Ctrl", ATTRS{serial}=="${disk.qemu.serial}", SYMLINK+="disk/by-id/nvme-eui.${disk.qemu.identifier}-part%n"
      ''
  ) (builtins.attrValues disks);
  qemuOptions =
    (lib.optionals needsScsiBus [
      "-device"
      "virtio-scsi-pci,id=scsi0"
    ])
    ++ builtins.concatLists diskQemuArgs;
}
