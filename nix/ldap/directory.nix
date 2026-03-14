{
  lib,
  instance,
}: let
  escapeDN =
    lib.replaceStrings
    ["\\" "," "+" "\"" "<" ">" ";" "=" "#" " " "\r" "\n" "\t"]
    ["\\5c" "\\2c" "\\2b" "\\22" "\\3c" "\\3e" "\\3b" "\\3d" "\\23" "\\20" "\\0d" "\\0a" "\\09"];
  suffix = "dc=${escapeDN instance.secondLevelDomain},dc=${escapeDN instance.topLevelDomain}";
  userDN = user: "uid=${escapeDN user.uid},ou=users,${suffix}";
  groupDN = group: "cn=${escapeDN group},ou=groups,${suffix}";
  users = lib.attrValues instance.users;
  groups = lib.groupBy (member: member.group) (lib.concatMap (user:
    map (group: {inherit group user;}) (lib.unique user.groups))
  users);
  password = hash:
    if lib.hasPrefix "{" hash
    then hash
    else "{CRYPT}${hash}";
in {
  inherit suffix;
  entries =
    [
      {
        dn = suffix;
        objectClass = ["dcObject" "organization" "top"];
        dc = instance.secondLevelDomain;
        o = "${instance.secondLevelDomain}.${instance.topLevelDomain}";
      }
      {
        dn = "ou=users,${suffix}";
        objectClass = ["organizationalUnit" "top"];
        ou = "users";
      }
      {
        dn = "ou=groups,${suffix}";
        objectClass = ["organizationalUnit" "top"];
        ou = "groups";
      }
    ]
    ++ lib.concatMap (user:
      lib.optional (user.gidNumber != null) {
        dn = groupDN user.uid;
        objectClass = ["top" "posixGroup"];
        gidNumber = toString user.gidNumber;
        cn = user.uid;
      }
      ++ [
        ({
            dn = userDN user;
            objectClass =
              ["inetOrgPerson" "person" "top"]
              ++ lib.optional (user.uidNumber != null && user.gidNumber != null) "posixAccount"
              ++ lib.optional (user.sshPublicKey != null) "ldapPublicKey"
              ++ lib.optional (user.agePublicKey != null) "agePublicKeyObject";
            cn = user.firstName;
            sn = user.lastName;
            inherit (user) mail uid;
            memberOf = map groupDN (lib.unique user.groups);
          }
          // lib.optionalAttrs (user.uidNumber != null && user.gidNumber != null) {
            homeDirectory = "/home/${user.uid}";
            uidNumber = toString user.uidNumber;
            gidNumber = toString user.gidNumber;
          }
          // lib.optionalAttrs (user.hashedPassword != null) {userPassword = password user.hashedPassword;}
          // lib.optionalAttrs (user.sshPublicKey != null) {inherit (user) sshPublicKey;}
          // lib.optionalAttrs (user.agePublicKey != null) {inherit (user) agePublicKey;})
      ])
    users
    ++ lib.mapAttrsToList (group: members: {
      dn = groupDN group;
      objectClass = ["groupOfUniqueNames" "top"];
      cn = group;
      uniqueMember = map (member: userDN member.user) members;
    })
    groups;
}
