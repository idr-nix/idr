{lib}: let
  ipv4ToInt = address: let
    parts = lib.splitString "." address;
    validPart = part: builtins.match "[0-9]{1,3}" part != null && lib.toInt part <= 255;
  in
    if builtins.length parts == 4 && lib.all validPart parts
    then lib.foldl' (value: part: value * 256 + lib.toInt part) 0 parts
    else throw "idr.microvm: invalid IPv4 address ${address}.";
  ipv4FromInt = value:
    lib.concatStringsSep "." (map (shift: toString (lib.mod (builtins.div value shift) 256)) [16777216 65536 256 1]);
  hostPrefix = prefix: hostId: "${lib.toLower prefix}:${builtins.substring 0 4 hostId}:${builtins.substring 4 4 hostId}";
in {
  inherit ipv4ToInt ipv4FromInt;

  parseIpv4Subnet = subnet: let
    parts = lib.splitString "/" subnet;
    address = builtins.head parts;
    prefixLength = lib.toInt (builtins.elemAt parts 1);
    size = lib.foldl' (value: _: value * 2) 1 (lib.genList (_: null) (32 - prefixLength));
    first = ipv4ToInt address;
  in
    if builtins.length parts != 2 || builtins.match "[0-9]{1,2}" (builtins.elemAt parts 1) == null || prefixLength > 30 || lib.mod first size != 0
    then throw "idr.microvm: ipv4Subnet must be an aligned IPv4 subnet with a prefix length from 0 to 30."
    else {
      inherit prefixLength first;
      last = first + size - 1;
      gateway = ipv4FromInt (first + 1);
      netmask = ipv4FromInt (4294967296 - size);
    };

  ipv6Address = prefix: hostId: machineId: "${hostPrefix prefix hostId}:${lib.concatStringsSep ":" (lib.genList (i: builtins.substring (i * 4) 4 machineId) 3)}";
  ipv6Subnet = prefix: hostId: "${hostPrefix prefix hostId}::/80";
  ipv6Gateway = prefix: hostId: "${hostPrefix prefix hostId}::1";

  linkLocalAddress = mac: let
    octets = lib.splitString ":" (lib.toLower mac);
    first = lib.toLower (lib.fixedWidthString 2 "0" (lib.toHexString (builtins.bitXor (lib.fromHexString (builtins.head octets)) 2)));
    at = builtins.elemAt octets;
  in "fe80::${first}${at 1}:${at 2}ff:fe${at 3}:${at 4}${at 5}";
}
