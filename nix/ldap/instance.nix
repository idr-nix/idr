instance: {
  lib,
  pkgs,
  ...
}: let
  directory = import ./directory.nix {inherit lib instance;};
  generator = pkgs.buildPackages.writers.writeNu "idr-ldap-directory" (builtins.readFile ./directory.nu);
  contents = pkgs.runCommand "idr-ldap-directory.ldif" {} ''
    ${generator} ${pkgs.writers.writeJSON "idr-ldap-directory.json" directory.entries} > "$out"
  '';
  credentials = "/run/credentials/openldap.service";
in {
  systemd.services.openldap.serviceConfig.LoadCredential =
    map
    (name: "${name}:/run/idr-ldap/${name}")
    ["cert" "cert-key" "root-password"];

  services.openldap = {
    enable = true;
    urlList = ["ldaps://:${toString instance.port}"];
    settings = {
      attrs = {
        olcLogLevel = "conns config";
        olcDisallows = "bind_anon";
        olcTLSCACertificateFile = "${credentials}/cert";
        olcTLSCertificateFile = "${credentials}/cert";
        olcTLSCertificateKeyFile = "${credentials}/cert-key";
      };
      children = {
        "cn=schema".includes = [
          "${pkgs.openldap}/etc/schema/core.ldif"
          "${pkgs.openldap}/etc/schema/cosine.ldif"
          "${pkgs.openldap}/etc/schema/inetorgperson.ldif"
          "${pkgs.openldap}/etc/schema/nis.ldif"
        ];
        "olcDatabase={0}config".attrs = {
          objectClass = "olcDatabaseConfig";
          olcDatabase = "{0}config";
          olcAccess = ["{0}to * by * none break"];
        };
        "olcDatabase={1}mdb".attrs = {
          objectClass = ["olcDatabaseConfig" "olcMdbConfig"];
          olcDatabase = "{1}mdb";
          olcDbDirectory = "/var/lib/openldap/data";
          olcRootPW.path = "${credentials}/root-password";
          olcRootDN = "cn=admin,${directory.suffix}";
          olcSuffix = directory.suffix;
          olcReadOnly = "TRUE";
          olcAccess = [
            ''
              {0}to *
                 by dn.base="uid=admin,ou=users,${directory.suffix}" write
                 by self read
                 by * search
            ''
          ];
        };
        "olcDatabase={2}monitor".attrs = {
          olcDatabase = "{2}monitor";
          objectClass = ["olcDatabaseConfig" "olcMonitorConfig"];
          olcAccess = ["{0}to * by * none"];
        };
        "olcOverlay={1}memberof,olcDatabase={1}mdb".attrs = {
          objectClass = ["olcConfig" "olcMemberOfConfig"];
          olcOverlay = "memberof";
          olcMemberOfRefint = "TRUE";
          olcMemberOfGroupOC = "groupOfUniqueNames";
          olcMemberOfMemberAD = "uniqueMember";
        };
        "cn={1}openssh,cn=schema".attrs = {
          cn = "{1}openssh";
          objectClass = "olcSchemaConfig";
          olcAttributeTypes = [
            ''
              (1.3.6.1.4.1.24552.500.1.1.1.13
                NAME 'sshPublicKey'
                DESC 'OpenSSH public key'
                EQUALITY octetStringMatch
                SYNTAX 1.3.6.1.4.1.1466.115.121.1.40 )
            ''
          ];
          olcObjectClasses = [
            ''
              (1.3.6.1.4.1.24552.500.1.1.2.0
                NAME 'ldapPublicKey'
                SUP top AUXILIARY
                DESC 'OpenSSH public key objectclass'
                MUST ( sshPublicKey $ uid ))
            ''
          ];
        };
        "cn={2}age,cn=schema".attrs = {
          cn = "{2}age";
          objectClass = "olcSchemaConfig";
          olcAttributeTypes = [
            ''
              (1.3.6.1.4.1.4203.666.1.100
                NAME 'agePublicKey'
                DESC 'age encryption public key'
                EQUALITY caseExactMatch
                SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
                SINGLE-VALUE )
            ''
          ];
          olcObjectClasses = [
            ''
              (1.3.6.1.4.1.4203.666.2.100
                NAME 'agePublicKeyObject'
                SUP top AUXILIARY
                DESC 'age encryption public key objectclass'
                MUST ( agePublicKey $ uid ))
            ''
          ];
        };
      };
    };
    declarativeContents.${directory.suffix} = ''
      include: file://${contents}
    '';
  };
}
