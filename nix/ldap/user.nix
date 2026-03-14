{
  name,
  config,
  lib,
  ...
}: {
  options = {
    uid = lib.mkOption {
      type = lib.types.str;
      default = name;
      defaultText = "<name>";
      description = "LDAP user name.";
    };
    firstName = lib.mkOption {
      type = lib.types.str;
      description = "Given name.";
    };
    lastName = lib.mkOption {
      type = lib.types.str;
      description = "Family name.";
    };
    mail = lib.mkOption {
      type = lib.types.str;
      description = "Email address.";
    };
    sshPublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SSH public key published in the directory.";
    };
    agePublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Age public key published in the directory.";
    };
    uidNumber = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = "POSIX user ID; omit for a non-POSIX account.";
    };
    gidNumber = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = config.uidNumber;
      defaultText = lib.literalExpression "config.uidNumber";
      description = "POSIX primary group ID.";
    };
    hashedPassword = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Password hash, for example from `openssl passwd -6`. Bare crypt hashes
        receive the LDAP {CRYPT} prefix; existing LDAP scheme prefixes are preserved.
      '';
    };
    groups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Directory groups this user belongs to.";
    };
  };
}
