import shlex


cluster_nodes = {"alpha": alpha, "beta": beta, "gamma": gamma}
proxy = "http://cluster.etcd.internal:65535"
root_password = "root-test-password"


def endpoint(name, address=None):
    host = address or f"{name}.example.test"
    if ":" in host:
        host = f"[{host}]"
    return f"https://{host}:{members[name]['publicPort']}"


def ctl(*args, user="root", password=root_password, url=None, ca=None):
    command = [
        "env",
        f"ETCDCTL_PASSWORD={password}",
        "etcdctl",
        "--dial-timeout=2s",
        "--command-timeout=5s",
        f"--endpoints={url or endpoint('beta')}",
    ]
    if user:
        command.append(f"--user={user}")
    if url != proxy:
        command.append(f"--cacert={ca or credentials + '/ca'}")
    return shlex.join([*command, *args])


def read(key, value, **kwargs):
    output = alpha.succeed(ctl("get", key, "--print-value-only", **kwargs)).strip()
    assert output == value, (key, output, value)


def denied(*args, **kwargs):
    status, output = alpha.execute(ctl(*args, **kwargs) + " 2>&1")
    assert status != 0, (args, output)
    assert any(
        error in output
        for error in [
            "permission denied",
            "authentication failed",
            "user name is empty",
        ]
    ), output


def invocation(machine, unit):
    return machine.succeed(f"systemctl show {unit} -p InvocationID --value").strip()


def member_status(name):
    return json.loads(
        alpha.succeed(ctl("endpoint", "status", "--write-out=json", url=endpoint(name)))
    )[0]["Status"]


def wait_for_member(name):
    cluster_nodes[name].wait_for_unit(f"idr-etcd-{name}.service")
    alpha.wait_until_succeeds(ctl("endpoint", "health", url=endpoint(name)), timeout=90)


def serial(name):
    return alpha.succeed(
        "openssl s_client "
        f"-connect {name}.example.test:{members[name]['publicPort']} "
        f"-CAfile {credentials}/ca -verify_return_error "
        f"-verify_hostname {name}.example.test -showcerts </dev/null 2>/dev/null "
        "| openssl x509 -noout -serial"
    ).strip()


start_all()
for machine in cluster_nodes.values():
    machine.wait_for_unit("multi-user.target")
alpha.wait_for_unit(rbac_unit)
alpha.wait_for_unit("idr-etcd-proxy-cluster.service")
for name in cluster_nodes:
    wait_for_member(name)
original = alpha.succeed("readlink -f /run/current-system").strip()

with subtest("three TLS members replicate through real IPv4 and IPv6 WireGuard peers"):
    cluster = json.loads(alpha.succeed(ctl("member", "list", "--write-out=json")))
    assert {member["name"] for member in cluster["members"]} == set(cluster_nodes), (
        cluster
    )
    for name, machine in cluster_nodes.items():
        machine.succeed("test ! -e /etc/systemd/system/idr-etcd-disabled.service")
        assert machine.succeed("wg show idr-etcd-wg listen-port").strip() == str(
            members[name]["wireguardPort"]
        )
        handshakes = machine.succeed(
            "wg show idr-etcd-wg latest-handshakes"
        ).splitlines()
        assert len(handshakes) == 2 and all(
            int(line.split()[1]) > 0 for line in handshakes
        ), handshakes
        traffic = machine.succeed("wg show idr-etcd-wg transfer").splitlines()
        assert all(
            int(received) > 0 and int(sent) > 0
            for _, received, sent in map(str.split, traffic)
        ), traffic
        assert (
            member_status(name)["header"]["cluster_id"]
            == cluster["header"]["cluster_id"]
        )
    alpha.succeed(ctl("put", "/persist", "replicated", url=endpoint("alpha")))
    for name in cluster_nodes:
        read("/persist", "replicated", url=endpoint(name))
    read("/persist", "replicated", url=proxy)
    assert "[2001:db8:2379::13]:51813" in alpha.succeed("wg show idr-etcd-wg endpoints")
    assert "192.0.2.12:51812" in alpha.succeed("wg show idr-etcd-wg endpoints")

with subtest(
    "a second local cluster stays independent and does not change peer source addresses"
):
    alpha.wait_for_unit("idr-etcd-aardvark.service")
    standalone = "https://alpha.example.test:2381"
    alpha.succeed(
        ctl("put", "/persist", "independent", url=standalone, user="", password="")
    )
    read("/persist", "independent", url=standalone, user="", password="")
    read("/persist", "replicated", url=endpoint("alpha"))
    status = json.loads(
        alpha.succeed(
            ctl(
                "endpoint",
                "status",
                "--write-out=json",
                url=standalone,
                user="",
                password="",
            )
        )
    )[0]["Status"]
    assert status["header"]["cluster_id"] != cluster["header"]["cluster_id"]
    for remote in ["beta", "gamma"]:
        route = alpha.succeed(f"ip -6 route get {private_addresses[remote]}")
        assert (
            "dev idr-etcd-wg" in route and f"src {private_addresses['alpha']}" in route
        ), route

with subtest(
    "clients verify server identity and the firewall permits only declared addresses"
):
    assert serial("beta") == "serial=01"
    for address in [members["beta"]["ipv4"], members["beta"]["ipv6"]]:
        read("/persist", "replicated", url=endpoint("beta", address))
        gamma.fail(f"nc -z -w 2 {shlex.quote(address)} {members['beta']['publicPort']}")
    alpha.fail(ctl("get", "/persist", ca=f"{credentials}/wrong-ca"))
    alpha.fail(ctl("get", "/persist", url=endpoint("beta", "wrong.example.test")))
    alpha.fail(ctl("get", "/persist", url=endpoint("beta").replace("https:", "http:")))
    denied("get", "/persist", user="", password="")
    denied("get", "/persist", password="incorrect")

with subtest("the proxy rejects an untrusted upstream certificate"):
    dropin = "/run/systemd/system/idr-etcd-proxy-cluster.service.d"
    alpha.succeed(
        f"mkdir -p {dropin}",
        "printf '%s\\n' '[Service]' "
        f"'Environment=SSL_CERT_FILE={credentials}/wrong-ca' > {dropin}/test-ca.conf",
        "systemctl daemon-reload",
        "systemctl restart idr-etcd-proxy-cluster.service",
    )
    alpha.wait_for_unit("idr-etcd-proxy-cluster.service")
    alpha.fail(ctl("get", "/persist", url=proxy))
    proxy_log = alpha.succeed(
        "journalctl -u idr-etcd-proxy-cluster.service --no-pager -o cat"
    )
    assert "x509: certificate signed by unknown authority" in proxy_log, proxy_log
    alpha.succeed(
        f"rm {dropin}/test-ca.conf",
        "systemctl daemon-reload",
        "systemctl restart idr-etcd-proxy-cluster.service",
    )
    alpha.wait_for_unit("idr-etcd-proxy-cluster.service")
    alpha.wait_until_succeeds(ctl("get", "/persist", url=proxy), timeout=30)
    read("/persist", "replicated", url=proxy)

with subtest("dynamic services consume credentials while source secrets stay private"):
    for name, machine in cluster_nodes.items():
        for secret in ["cert", "key", "wireguard-key", "wireguard-psk"]:
            assert (
                machine.succeed(
                    f"stat -c '%a %U %G' /run/etcd-test-secrets/{secret}"
                ).strip()
                == "400 root root"
            )
            machine.fail(f"runuser -u nobody -- cat /run/idr-secrets/{secret}")
        machine.fail(f"runuser -u idr-etcd-{name} -- cat /run/idr-secrets/key")
        machine.succeed(f"test -s /srv/etcd/{name}/member/snap/db")

with subtest(
    "a lost proxy backend leaves quorum and catches up after its persisted member restarts"
):
    member_id = member_status("beta")["header"]["member_id"]
    beta.succeed("systemctl stop idr-etcd-beta.service")
    alpha.wait_until_succeeds(
        ctl("put", "/during-outage", "available", url=proxy), timeout=60
    )
    read("/during-outage", "available", url=endpoint("gamma"))
    read("/persist", "replicated", url=proxy)
    beta.succeed("systemctl start idr-etcd-beta.service")
    wait_for_member("beta")
    read("/during-outage", "available", url=endpoint("beta"))
    beta.shutdown()
    beta.start()
    wait_for_member("beta")
    assert member_status("beta")["header"]["member_id"] == member_id
    read("/persist", "replicated", url=endpoint("beta"))
    read("/during-outage", "available", url=endpoint("beta"))

with subtest(
    "declarative users enforce exact, prefix, Unicode prefix and range permissions"
):
    for key in [
        "/app/item",
        "/exact",
        "/range/a",
        "/range/b",
        "/range/c",
        "/range/d",
        "/new/item",
        "/added",
    ]:
        alpha.succeed(ctl("put", key, "initial"))
    writer = {"user": "writer", "password": "writer-test-password"}
    reader = {"user": "reader", "password": "reader-test-password"}
    read("/app/item", "initial", **writer)
    read("/app/item", "initial", **reader)
    for key in ["/app/item", "/exact", "/range/b", "/ÿ/item"]:
        alpha.succeed(ctl("put", key, "written", **writer))
    read("/ÿ/item", "written", **writer)
    read("/exact", "written", **writer)
    for key in ["/application", "/exact-suffix", "/range/d", "/new/item"]:
        denied("put", key, "denied", **writer)
    denied("put", "/app/item", "denied", **reader)
    denied("get", "/range/b", **reader)
    alpha.succeed(
        ctl(
            "put",
            "/obsolete",
            "old",
            user="obsolete",
            password="obsolete-test-password",
        )
    )

with subtest(
    "a certificate secret refresh restarts the member and serves the replaced certificate"
):
    before = invocation(beta, "idr-etcd-beta.service")
    beta.succeed(
        f"install -m 0400 {credentials}/beta-cert-2 /run/etcd-test-secrets/cert.new",
        "mv /run/etcd-test-secrets/cert.new /run/etcd-test-secrets/cert",
        "systemctl restart etcd-test-secrets-restart.target",
    )
    wait_for_member("beta")
    assert invocation(beta, "idr-etcd-beta.service") != before
    assert serial("beta") == "serial=02"
    read("/persist", "replicated", url=endpoint("beta"))

with subtest(
    "switching to a proxy-only host reconciles removed users, roles and permissions"
):
    alpha.succeed(f"{original}/specialisation/updated/bin/switch-to-configuration test")
    alpha.wait_for_unit(rbac_unit)
    alpha.wait_for_unit("idr-etcd-proxy-cluster.service")
    alpha.succeed("test ! -e /etc/systemd/system/idr-etcd-alpha.service")
    alpha.fail("systemctl is-active idr-etcd-alpha.service")
    alpha.wait_until_succeeds(ctl("get", "/persist", url=proxy), timeout=60)
    read("/persist", "replicated", url=proxy)
    assert set(alpha.succeed(ctl("user", "list")).splitlines()) == {
        "root",
        "writer",
        "reader",
        "newcomer",
    }
    assert set(alpha.succeed(ctl("role", "list")).splitlines()) == {
        "root",
        "read",
        "write",
        "added",
    }
    denied("get", "/new/item", **writer)
    writer["password"] = "writer-updated-password"
    for key in ["/app/item", "/exact", "/range/a", "/range/c", "/ÿ/item"]:
        denied("get", key, **writer)
    read("/range/b", "written", **writer)
    denied("put", "/range/b", "denied", **writer)
    alpha.succeed(ctl("put", "/new/item", "updated", url=proxy, **writer))
    read("/new/item", "updated", **reader)
    read("/added", "initial", **reader)
    denied("get", "/app/item", **reader)
    read("/added", "initial", user="newcomer", password="newcomer-test-password")
    denied("get", "/obsolete", user="obsolete", password="obsolete-test-password")

with subtest(
    "secret target refresh changes the user password and unchanged reconciliation is idempotent"
):
    before = invocation(alpha, rbac_unit)
    alpha.succeed(
        f"install -m 0400 {credentials}/writer-password-rotated /run/etcd-test-secrets/writer-password-updated.new",
        "mv /run/etcd-test-secrets/writer-password-updated.new /run/etcd-test-secrets/writer-password-updated",
        "systemctl restart etcd-test-secrets-restart.target",
    )
    alpha.wait_for_unit(rbac_unit)
    assert invocation(alpha, rbac_unit) != before
    denied("get", "/new/item", **writer)
    writer["password"] = "writer-rotated-password"
    read("/new/item", "updated", url=proxy, **writer)
    revision = json.loads(alpha.succeed(ctl("auth", "status", "--write-out=json")))[
        "authRevision"
    ]
    alpha.succeed(f"systemctl restart {rbac_unit}")
    alpha.wait_for_unit(rbac_unit)
    assert (
        json.loads(alpha.succeed(ctl("auth", "status", "--write-out=json")))[
            "authRevision"
        ]
        == revision
    )
    read("/new/item", "updated", url=proxy, **writer)
