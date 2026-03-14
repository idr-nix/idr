import base64
import shlex


BASE = "dc=example,dc=test"
ADMIN = f"cn=admin,{BASE}"
URI = "ldaps://ldap.example.test:636"
CA = "/run/ldap-test-ca"
PASSWORD = "admin-test-password"


def user_dn(uid):
    return f"uid={uid},ou=users,{BASE}"


def group_dn(name):
    return f"cn={name},ou=groups,{BASE}"


def ldap_command(program, arguments=(), dn=ADMIN, password=None, uri=URI):
    return shlex.join(
        [
            "env",
            f"LDAPTLS_CACERT={CA}",
            "LDAPTLS_REQCERT=demand",
            program,
            "-x",
            "-H",
            uri,
            "-o",
            "nettimeout=3",
            "-D",
            dn,
            "-w",
            PASSWORD if password is None else password,
            *arguments,
        ]
    )


def search(base=BASE, query="(objectClass=*)", dn=ADMIN, password=None):
    output = machine.succeed(
        ldap_command(
            "ldapsearch",
            ["-LLL", "-o", "ldif-wrap=no", "-b", base, query, "*", "+"],
            dn=dn,
            password=password,
        )
    )
    records = {}
    for block in output.strip().split("\n\n"):
        attributes = {}
        for line in block.splitlines():
            if not line or line.startswith("#"):
                continue
            name, value = line.split(":", 1)
            if value.startswith(":"):
                value = base64.b64decode(value[1:].strip()).decode()
            else:
                value = value.lstrip()
            attributes.setdefault(name.lower(), []).append(value)
        if attributes:
            records[attributes["dn"][0]] = attributes
    return records


def entry(base, **kwargs):
    return search(base=base, **kwargs)[base]


def container(command):
    return machine.succeed(f"nixos-container run ldap-primary -- {command}")


def invocation():
    return machine.succeed(
        "systemctl show container@ldap-primary.service -p InvocationID --value"
    ).strip()


def wait_for_ldap():
    machine.wait_for_unit("container@ldap-primary.service")
    machine.wait_until_succeeds(
        "nixos-container run ldap-primary -- systemctl is-active openldap.service",
        timeout=60,
    )
    machine.wait_until_succeeds(ldap_command("ldapwhoami"), timeout=60)


def tls_serial():
    return machine.succeed(
        "openssl s_client -connect ldap.example.test:636 "
        f"-CAfile {CA} -verify_return_error -verify_hostname ldap.example.test "
        "-showcerts </dev/null 2>/dev/null | openssl x509 -noout -serial"
    ).strip()


start_all()
machine.wait_for_unit("multi-user.target")
wait_for_ldap()
original = machine.succeed("readlink -f /run/current-system").strip()

with subtest(
    "declared instances start automatically and disabled instances stay absent"
):
    machine.succeed("test ! -e /etc/nixos-containers/ldap-disabled.conf")
    assert machine.succeed("nixos-container list").splitlines() == ["ldap-primary"]
    assert machine.succeed(ldap_command("ldapwhoami")).strip() == f"dn:{ADMIN}"
    assert tls_serial() == "serial=01"
    machine.fail(ldap_command("ldapwhoami", uri="ldap://ldap.example.test:389"))
    machine.fail(ldap_command("ldapwhoami", uri="ldaps://localhost:636"))
    machine.fail(ldap_command("ldapwhoami", password="incorrect-password"))
    machine.fail(ldap_command("ldapwhoami", dn="", password=""))

with subtest(
    "human team members supply users and optional POSIX, SSH, age and group data"
):
    users = search(base=f"ou=users,{BASE}", query="(objectClass=inetOrgPerson)")
    assert set(users) == {user_dn("alice"), user_dn("bob"), user_dn("service")}
    alice = users[user_dn("alice")]
    expected_alice = {
        "uid": "alice",
        "cn": fixture_team["alice"]["firstName"],
        "sn": fixture_team["alice"]["lastName"],
        "mail": "alice.override@example.test",
        "uidnumber": "10001",
        "gidnumber": "10001",
        "homedirectory": "/home/alice",
        "sshpublickey": fixture_team["alice"]["sshPublicKey"],
        "agepublickey": fixture_team["alice"]["agePublicKey"],
        "userpassword": "{CRYPT}" + fixture_team["alice"]["hashedPassword"],
    }
    for name, value in expected_alice.items():
        assert alice[name] == [value], (name, alice)
    assert {"posixAccount", "ldapPublicKey", "agePublicKeyObject"}.issubset(
        alice["objectclass"]
    )
    assert set(alice["memberof"]) == {group_dn("operators"), group_dn("engineering")}
    assert entry(group_dn("alice"))["gidnumber"] == ["10001"]
    assert set(entry(group_dn("operators"))["uniquemember"]) == {
        user_dn("alice"),
        user_dn("service"),
    }
    assert entry(group_dn("engineering"))["uniquemember"] == [user_dn("alice")]

    bob = users[user_dn("bob")]
    assert bob["cn"] == ["Bob"]
    assert bob["mail"] == ["bob@example.test"]
    assert "posixAccount" not in bob["objectclass"]
    for name in [
        "uidnumber",
        "gidnumber",
        "homedirectory",
        "sshpublickey",
        "agepublickey",
        "userpassword",
        "memberof",
    ]:
        assert name not in bob, bob

    custom = users[user_dn("service")]
    assert custom["cn"] == [custom_user["firstName"]]
    assert custom["mail"] == [custom_user["mail"]]
    assert custom["userpassword"] == [custom_user["hashedPassword"]]
    assert custom["memberof"] == [group_dn("operators")]

with subtest("raw crypt and LDAP-prefixed passwords authenticate real user binds"):
    for uid, password in [
        ("alice", "alice-test-password"),
        ("service", "custom-test-password"),
    ]:
        assert (
            machine.succeed(
                ldap_command("ldapwhoami", dn=user_dn(uid), password=password)
            ).strip()
            == f"dn:{user_dn(uid)}"
        )
        assert entry(user_dn(uid), dn=user_dn(uid), password=password)["uid"] == [uid]
    machine.fail(
        ldap_command("ldapwhoami", dn=user_dn("alice"), password="incorrect-password")
    )
    machine.fail(
        ldap_command("ldapwhoami", dn=user_dn("bob"), password="no-password-is-set")
    )
    change = (
        f"dn: {user_dn('alice')}\nchangetype: modify\nreplace: mail\n"
        "mail: changed-by-client@example.test\n"
    )
    machine.fail(
        f"printf %s {shlex.quote(change)} | "
        + ldap_command(
            "ldapmodify", dn=user_dn("alice"), password="alice-test-password"
        )
    )
    assert entry(user_dn("alice"))["mail"] == ["alice.override@example.test"]

with subtest("runtime credentials keep host secrets private and bind mounts read-only"):
    slapd_pid = container("systemctl show openldap.service -p MainPID --value").strip()
    assert slapd_pid.isdigit() and int(slapd_pid) > 0, slapd_pid

    def service_namespace(command):
        return container(f"nsenter --target {slapd_pid} --mount -- {command}")

    for name in ["cert", "cert-key", "root-password"]:
        source = machine.succeed(
            f"stat -c '%a %U %G' /run/ldap-test-secrets/{name}"
        ).strip()
        assert source == "400 root root", (name, "host source", source)
        bound = container(f"stat -c '%a %U %G' /run/idr-ldap/{name}").strip()
        assert bound == "400 root root", (name, "bound source", bound)
        container(f"test ! -w /run/idr-ldap/{name}")
        service_namespace(f"runuser -u openldap -- test ! -r /run/idr-ldap/{name}")

        # Verify access in the service's mount namespace. Systemd can use ACLs
        # to grant its User access without changing credential ownership.
        credential = f"/run/credentials/openldap.service/{name}"
        metadata = service_namespace(f"stat -c '%a %U %G' {credential}").strip()
        print(f"{credential}: {metadata}")
        permissions = int(metadata.split()[0], 8)
        assert permissions & 0o227 == 0, (credential, metadata)
        service_namespace(f"runuser -u openldap -- cat {credential} >/dev/null")
        service_namespace(f"runuser -u openldap -- test ! -w {credential}")
        service_namespace(f"runuser -u nobody -- test ! -r {credential}")
        service_namespace(f"test ! -w {credential}")
        machine.fail(
            "nixos-container run ldap-primary -- "
            f"nsenter --target {slapd_pid} --mount -- "
            f"runuser -u nobody -- cat {credential} >/dev/null"
        )
    container("test ! -d /run/ldap-test-secrets")
    for name in ["cert", "cert-key"]:
        container(
            "grep -Fq "
            f"'/run/credentials/openldap.service/{name}' /etc/openldap/slapd.d/cn=config.ldif"
        )
    container("systemctl show openldap.service -p User --value | grep -Fx openldap")

with subtest("the firewall permits only the declared IPv4 and IPv6 clients"):
    machine.succeed(
        "ip netns add ldap-client",
        "ip link add ldap-server type veth peer name ldap-client",
        "ip link set ldap-client netns ldap-client",
        "ip addr add 192.0.2.1/24 dev ldap-server",
        "ip -6 addr add 2001:db8:636::1/64 dev ldap-server nodad",
        "ip link set ldap-server up",
        "ip netns exec ldap-client ip link set lo up",
        "ip netns exec ldap-client ip link set ldap-client up",
        "ip netns exec ldap-client ip addr add 192.0.2.2/24 dev ldap-client",
        "ip netns exec ldap-client ip -6 addr add 2001:db8:636::2/64 dev ldap-client nodad",
    )
    for uri in ["ldaps://192.0.2.1:636", "ldaps://[2001:db8:636::1]:636"]:
        status, output = machine.execute(
            "ip netns exec ldap-client " + ldap_command("ldapwhoami", uri=uri)
        )
        if status:
            print(output)
            for diagnostic in [
                "ip -6 addr show dev ldap-server",
                "ip -6 route show",
                "ip -6 neigh show dev ldap-server",
                "ip netns exec ldap-client ip -6 addr show",
                "ip netns exec ldap-client ip -6 route show",
                "ip netns exec ldap-client ip -6 neigh show",
                "ss -lntp",
                "nft list ruleset",
            ]:
                print(diagnostic, machine.execute(diagnostic))
        assert status == 0, (uri, status, output)
    machine.succeed(
        "ip netns exec ldap-client ip addr del 192.0.2.2/24 dev ldap-client",
        "ip netns exec ldap-client ip -6 addr del 2001:db8:636::2/64 dev ldap-client",
        "ip netns exec ldap-client ip addr add 192.0.2.3/24 dev ldap-client",
        "ip netns exec ldap-client ip -6 addr add 2001:db8:636::3/64 dev ldap-client nodad",
    )
    for uri in ["ldaps://192.0.2.1:636", "ldaps://[2001:db8:636::1]:636"]:
        machine.fail(
            "ip netns exec ldap-client timeout 5 " + ldap_command("ldapwhoami", uri=uri)
        )

with subtest("a configuration switch applies updated declarative user data"):
    machine.succeed(
        f"{original}/specialisation/updated/bin/switch-to-configuration test"
    )
    wait_for_ldap()
    assert entry(user_dn("alice"))["mail"] == ["alice.updated@example.test"]
    assert entry(user_dn("bob"))["mail"] == ["bob@example.test"]
    assert set(entry(group_dn("operators"))["uniquemember"]) == {
        user_dn("alice"),
        user_dn("service"),
    }

with subtest(
    "secret restart targets refresh replaced certificate and root password files"
):
    before = invocation()
    machine.succeed(
        f"install -m 0400 {tls_fixtures}/cert-2 /run/ldap-test-secrets/cert.new",
        "mv /run/ldap-test-secrets/cert.new /run/ldap-test-secrets/cert",
        f"install -m 0400 {tls_fixtures}/root-password-rotated "
        "/run/ldap-test-secrets/root-password.new",
        "mv /run/ldap-test-secrets/root-password.new /run/ldap-test-secrets/root-password",
        f"install -m 0444 {tls_fixtures}/cert-2 {CA}",
        "systemctl restart ldap-test-secrets-restart.target",
    )
    PASSWORD = "admin-rotated-password"
    wait_for_ldap()
    assert invocation() != before
    assert tls_serial() == "serial=02"
    machine.fail(ldap_command("ldapwhoami", password="admin-test-password"))
    assert entry(user_dn("alice"))["mail"] == ["alice.updated@example.test"]
    assert entry(user_dn("service"))["userpassword"] == [custom_user["hashedPassword"]]
