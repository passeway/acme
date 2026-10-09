"""Hermetic regressions: no live CA, DNS API or host service changes."""
import base64
import io
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "acme.sh"
q = shlex.quote


class ManagerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.fixtures.cleanup)
        cls.fixture = Path(cls.fixtures.name)
        for name, san in (("valid", "DNS:example.com,DNS:*.example.com"),
                          ("other", "DNS:other.example"),
                          ("single", "DNS:example.com")):
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "ec",
                "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1",
                "-subj", "/CN=example.com", "-addext", f"subjectAltName={san}",
                "-keyout", str(cls.fixture / f"{name}.key"),
                "-out", str(cls.fixture / f"{name}.crt"),
            ], check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.prefix = f"""
set -o pipefail
source {q(str(SCRIPT))}
ACME_HOME={q(str(self.path / 'acme'))}
CERT_DIR={q(str(self.path / 'cert'))}
STATE_DIR={q(str(self.path / 'state'))}
LOCK_FILE={q(str(self.path / 'lock'))}
RENEW_SCRIPT={q(str(self.path / 'libexec/renew'))}
RENEW_LOG={q(str(self.path / 'renew.log'))}
SYSTEM_CRONTAB={q(str(self.path / 'system.cron'))}
RUN_TMP={q(str(self.path / 'tmp'))}
OS_RELEASE={q(str(self.path / 'os-release'))}
mkdir -p "$ACME_HOME" "$CERT_DIR" "$STATE_DIR" "$RUN_TMP"
"""

    def shell(self, code, data="", status=0):
        r = subprocess.run(["bash", "-c", self.prefix + code], input=data,
                           text=True, capture_output=True, timeout=15)
        self.assertEqual(r.returncode, status, r.stdout + r.stderr)
        return r

    def make_certificate(self, name="valid"):
        target = self.path / "acme/example.com_ecc"
        target.mkdir(parents=True, exist_ok=True)
        (target / "fullchain.cer").write_bytes((self.fixture / f"{name}.crt").read_bytes())
        (target / "example.com.key").write_bytes((self.fixture / f"{name}.key").read_bytes())
        (target / "example.com.conf").write_text("Le_Domain='example.com'\n")

    def cron_stub(self):
        return """
crontab() {
    if [[ "$1" == -l ]]; then cat "$STATE_DIR/current.cron"
    else cat "$1" > "$STATE_DIR/current.cron"; fi
}
start_cron() { :; }
"""

    def seed_cron(self, text="0 1 * * * /opt/backup --cron\n"):
        (self.path / "state").mkdir(exist_ok=True)
        (self.path / "state/current.cron").write_text(text)

    def issue_stub(self, code=0):
        return f"""
require_ready() {{ :; }}
read_domain() {{ domain=example.com; }}
read_reload() {{ reload_cmd=; }}
read_cf_credentials() {{ :; }}
acme() {{ printf '%s\\n' "$@" >> "$STATE_DIR/calls"; return {code}; }}
"""

    def test_os_mapping(self):
        for identifier, family, service in [
            ("debian", "debian", "cron"), ("ubuntu", "debian", "cron"),
            ("alpine", "alpine", "crond"), ("rocky", "rhel", "crond"),
            ("fedora", "rhel", "crond"), ("amzn", "rhel", "crond")
        ]:
            (self.path / "os-release").write_text(f"ID={identifier}\n")
            result = self.shell('detect_system; printf "%s %s" "$SYSTEM" "$CRON_SERVICE"')
            self.assertEqual(result.stdout, family + " " + service)
        (self.path / "os-release").write_text("ID=unknown\n")
        self.shell("detect_system", status=1)

    def test_dependencies_use_correct_alpine_and_rhel_cron(self):
        for family, expected in [("alpine", "busybox-openrc"), ("rhel", "cronie"),
                                 ("debian", "cron")]:
            result = self.shell(f"""
SYSTEM={family}
install_packages() {{ printf '%s\\n' "$*"; }}
have() {{ return 0; }}
install_dependencies
""")
            self.assertIn(expected, result.stdout)
            self.assertNotIn("busybox-initscripts", result.stdout)
            self.assertNotIn("dnsutils", result.stdout)
            self.assertNotIn("upgrade", result.stdout)

    def test_dependency_failure_stops_install(self):
        out = self.shell("install_dependencies() { return 9; }; install_client() { echo BAD; }; install_manager", status=1)
        self.assertNotIn("BAD", out.stdout)

    def test_domains_reject_paths_options_and_shell_input(self):
        for domain in ("", "../example.com", "-d.other", "a..com", "a;id.com",
                       "*.example.com", "example.com:80", "127.0.0.1",
                       "a\nx.com", "a" * 64 + ".com", "a.-b.com"):
            self.shell("valid_domain " + q(domain), status=1)
        self.assertEqual(self.shell('read_domain; printf "%s" "$domain"',
                                    "Example.COM.\n").stdout, "example.com")

    def test_blank_email_is_not_invented(self):
        self.assertEqual(self.shell('read_email; printf "<%s>" "$email"', "\n").stdout, "<>")
        self.shell("read_email", "wrong mail@example.com\n", status=1)

    def test_port_conflict_never_stops_service(self):
        for output in ("LISTEN 0 128 0.0.0.0:80 0.0.0.0:*",
                       "LISTEN 0 128 [::]:80 [::]:*"):
            self.shell(f"ss() {{ echo {q(output)}; }}; check_http_port", status=1)
        self.shell("ss() { echo 'LISTEN 0 128 *:8080 *:*'; }; check_http_port")

    def test_busybox_netstat_port_detection(self):
        self.shell("""
have() { [[ "$1" == netstat ]]; }
netstat() { echo 'tcp 0 0 :::80 :::* LISTEN'; }
check_http_port
""", status=1)

    def test_lock_released_between_operations(self):
        self.shell("with_lock true; with_lock true")
        self.shell("with_lock with_lock true", status=1)

    def test_acme_child_does_not_inherit_lock(self):
        target = self.path / "acme/acme.sh"
        target.parent.mkdir()
        target.write_text("#!/bin/sh\n[ ! -e /proc/self/fd/9 ]\n")
        target.chmod(0o700)
        self.shell("with_lock acme --version")

    def test_cron_filter_preserves_other_commands_and_hooks(self):
        home = self.path / "acme"
        original = (
            "# keep --cron\n"
            "0 0 * * * root /other/acme.sh --cron -f\n"
            "0 0 * * * root /opt/app --cron\n"
            f"0 0 * * * root bash {home}/acme.sh --cron -f >/dev/null 2>&1\n"
            f"0 0 * * * root {home}/acme.sh --cron && /opt/reload\n"
        )
        p = self.path / "system.cron"
        p.write_text(original)
        result = self.shell('filter_cron "$SYSTEM_CRONTAB" 1').stdout
        self.assertNotIn("bash " + str(home), result)
        self.assertIn("/other/acme.sh --cron -f", result)
        self.assertIn("--cron && /opt/reload", result)
        self.assertIn("# keep --cron", result)

    def test_schedule_migrates_and_is_idempotent(self):
        home = self.path / "acme"
        self.seed_cron(f'5 2 * * * "{home}"/acme.sh --cron --home "{home}" > /dev/null\n'
                       "0 1 * * * /opt/backup --cron\n")
        (self.path / "system.cron").write_text(
            f"0 0 * * * root bash {home}/acme.sh --cron -f >/dev/null 2>&1\n"
            "5 4 * * * root /opt/task --cron\n")
        self.shell(self.cron_stub() + "configure_schedule; configure_schedule")
        content = (self.path / "state/current.cron").read_text()
        self.assertEqual(content.count("# passeway-acme-renew"), 1)
        self.assertIn("/opt/backup --cron", content)
        self.assertEqual((self.path / "system.cron").read_text(), "5 4 * * * root /opt/task --cron\n")
        self.assertTrue(list((self.path / "state").glob("cron-*/system.crontab")))

    def test_crontab_read_error_does_not_overwrite(self):
        out = self.shell("""
crontab() { if [[ "$1" == -l ]]; then echo 'permission denied' >&2; return 1; else echo BAD; fi; }
configure_schedule
""", status=1)
        self.assertNotIn("BAD", out.stdout)

    def test_crontab_empty_detection_for_both_implementations(self):
        for message in ("no crontab for root", "crontab: can't open 'root': No such file or directory"):
            self.shell(f'crontab() {{ echo {q(message)} >&2; return 1; }}; read_root_cron "$RUN_TMP/current"')

    def test_custom_schedule_requires_explicit_migration(self):
        self.seed_cron(f"0 0 * * * {self.path}/acme/acme.sh --cron && /opt/reload\n")
        self.shell(self.cron_stub() + "configure_schedule", status=1)
        self.shell(self.cron_stub() + "configure_schedule remove", status=1)
        self.assertIn("&& /opt/reload", (self.path / "state/current.cron").read_text())

    def test_system_cron_write_failure_restores_root_cron(self):
        self.seed_cron()
        original = (self.path / "state/current.cron").read_text()
        system = f"0 0 * * * root bash {self.path}/acme/acme.sh --cron -f >/dev/null 2>&1\n"
        (self.path / "system.cron").write_text(system)
        self.shell(self.cron_stub() + """
mv() { if [[ "${@: -1}" == "$SYSTEM_CRONTAB" ]]; then return 19; else command mv "$@"; fi; }
configure_schedule
""", status=1)
        self.assertEqual((self.path / "state/current.cron").read_text(), original)
        self.assertEqual((self.path / "system.cron").read_text(), system)

    def test_system_cron_staging_failure_leaves_both_tables_unchanged(self):
        self.seed_cron()
        original = (self.path / "state/current.cron").read_text()
        system = f"0 0 * * * root bash {self.path}/acme/acme.sh --cron -f >/dev/null 2>&1\n"
        (self.path / "system.cron").write_text(system)
        self.shell(self.cron_stub() + """
mktemp() { if [[ "$1" == "$SYSTEM_CRONTAB.tmp."* ]]; then return 19; else command mktemp "$@"; fi; }
configure_schedule
""", status=1)
        self.assertEqual((self.path / "state/current.cron").read_text(), original)
        self.assertEqual((self.path / "system.cron").read_text(), system)

    def test_renew_runner_uses_shared_lock_and_propagates_failure(self):
        self.shell("write_renew_script")
        client = self.path / "acme/acme.sh"
        client.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" > {q(str(self.path / "args"))}\nexit 17\n')
        client.chmod(0o700)
        self.shell('bash "$RENEW_SCRIPT"', status=17)
        args = (self.path / "args").read_text()
        self.assertIn("--cron", args)
        self.assertNotIn(" -f", args)
        self.assertIn("退出码 17", (self.path / "renew.log").read_text())
        (self.path / "args").unlink()
        self.shell('with_lock bash "$RENEW_SCRIPT"')
        self.assertFalse((self.path / "args").exists())

    def test_legacy_tls_bypass_is_removed_with_private_backup(self):
        conf = self.path / "acme/account.conf"
        conf.parent.mkdir()
        original = "HTTPS_INSECURE='1'\nACCOUNT_EMAIL='a@example.com'\nSAVED_CF_Key='placeholder'\n"
        conf.write_text(original)
        self.shell("restore_tls_verification")
        self.assertNotIn("HTTPS_INSECURE=", conf.read_text())
        backup = list((self.path / "state").glob("account-*.conf"))[0]
        self.assertEqual(backup.read_text(), original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)

    def test_issue_failure_does_not_deploy_old_certificate(self):
        self.make_certificate()
        self.shell(self.issue_stub(19) + 'issue_certificate dns', status=1)
        self.assertNotIn("--install-cert", (self.path / "state/calls").read_text())

    def test_wildcard_is_literal_and_root_domain_is_primary(self):
        result = self.shell(self.issue_stub() + """
deploy_certificate() { printf 'DEPLOY %s %s\\n' "$1" "$2"; }
issue_certificate wildcard
""")
        args = (self.path / "state/calls").read_text().splitlines()
        self.assertEqual(args[args.index("-d") + 1], "example.com")
        self.assertIn("*.example.com", args)
        self.assertNotIn("--insecure", args)
        self.assertNotIn("--force", args)
        self.assertIn("DEPLOY example.com 1", result.stdout)

    def test_ipv6_standalone_flag(self):
        self.shell(self.issue_stub() + """
check_http_port() { :; }
deploy_certificate() { :; }
issue_certificate standalone
""", data="2\n")
        self.assertIn("--listen-v6", (self.path / "state/calls").read_text())

    def test_legacy_wildcard_uses_existing_main_domain(self):
        legacy = self.path / "acme/*.example.com_ecc"
        legacy.mkdir(parents=True)
        (legacy / "*.example.com.conf").write_text("Le_Domain='*.example.com'\n")
        out = self.shell(self.issue_stub() + """
deploy_certificate() { printf 'DEPLOY %s\\n' "$1"; }
issue_certificate wildcard
""")
        args = (self.path / "state/calls").read_text().splitlines()
        self.assertEqual(args[args.index("-d") + 1], "*.example.com")
        self.assertIn("DEPLOY *.example.com", out.stdout)
        self.shell(self.issue_stub() + "issue_certificate dns", status=1)

    def test_legacy_wildcard_deploys_to_original_base_paths(self):
        legacy = self.path / "acme/*.example.com_ecc"
        legacy.mkdir(parents=True)
        (legacy / "fullchain.cer").write_bytes((self.fixture / "valid.crt").read_bytes())
        (legacy / "*.example.com.key").write_bytes((self.fixture / "valid.key").read_bytes())
        self.shell("""
reload_cmd=
acme() { printf '%s\\n' "$@" > "$STATE_DIR/calls"; }
deploy_certificate '*.example.com' 1
""")
        args = (self.path / "state/calls").read_text().splitlines()
        self.assertEqual(args[args.index("--key-file") + 1], str(self.path / "cert/example.com.key"))

    def test_skipped_issue_still_requires_valid_certificate(self):
        self.shell(self.issue_stub(2) + "issue_certificate dns", status=1)
        self.assertNotIn("--install-cert", (self.path / "state/calls").read_text())

    def test_real_certificate_key_and_san_checks(self):
        for name in ("valid", "single"):
            cert, key = self.fixture / f"{name}.crt", self.fixture / f"{name}.key"
            self.shell(f"validate_pair {q(str(cert))} {q(str(key))} example.com 0")
            self.shell(f"validate_pair {q(str(cert))} {q(str(key))} example.com 1",
                       status=0 if name == "valid" else 1)
        self.shell(f"validate_pair {self.fixture}/valid.crt {self.fixture}/other.key example.com", status=1)
        self.shell(f"validate_pair {self.fixture}/other.crt {self.fixture}/other.key example.com", status=1)

    def test_failed_deployment_restores_existing_files(self):
        self.make_certificate()
        (self.path / "cert").mkdir()
        (self.path / "cert/example.com.key").write_text("old-key")
        (self.path / "cert/example.com.crt").write_text("old-cert")
        self.shell("""
reload_cmd=false
acme() { echo bad > "$CERT_DIR/example.com.key"; echo bad > "$CERT_DIR/example.com.crt"; return 1; }
deploy_certificate example.com
""", status=1)
        self.assertEqual((self.path / "cert/example.com.key").read_text(), "old-key")
        self.assertEqual((self.path / "cert/example.com.crt").read_text(), "old-cert")

    def test_failed_first_deployment_removes_partial_files(self):
        self.make_certificate()
        self.shell("reload_cmd=; acme() { return 1; }; deploy_certificate example.com", status=1)
        self.assertFalse((self.path / "cert/example.com.key").exists())
        self.assertFalse((self.path / "cert/example.com.crt").exists())

    def test_symlink_destinations_are_rejected(self):
        self.make_certificate()
        (self.path / "cert").mkdir()
        victim = self.path / "victim"
        victim.write_text("do-not-touch")
        (self.path / "cert/example.com.key").symlink_to(victim)
        self.shell("reload_cmd=; deploy_certificate example.com", status=1)
        self.assertEqual(victim.read_text(), "do-not-touch")

    def test_reload_is_preserved_without_evaluating_config(self):
        self.make_certificate()
        command = f"nginx -t && printf ok > {self.path}/must-not-run"
        encoded = base64.b64encode(command.encode()).decode()
        (self.path / "acme/example.com_ecc/example.com.conf").write_text(
            f"Le_ReloadCmd='__ACME_BASE64__START_{encoded}__ACME_BASE64__END_'\n")
        result = self.shell('read_reload example.com; printf "COMMAND=%s" "$reload_cmd"', "\n")
        self.assertIn("COMMAND=" + command, result.stdout)
        self.assertFalse((self.path / "must-not-run").exists())
        result = self.shell('read_reload example.com; printf "COMMAND=<%s>" "$reload_cmd"', "none\n")
        self.assertIn("COMMAND=<>", result.stdout)

    def test_token_is_scoped_without_echo(self):
        out = self.shell("""
CF_Key=old; CF_Email=old
read_cf_credentials || exit 1
[[ "$CF_Token" == example-token && "$CF_Zone_ID" == 0123456789abcdef0123456789abcdef ]]
[[ -z "${CF_Key:-}" && -z "${CF_Email:-}" ]]
""", "1\nexample-token\n0123456789abcdef0123456789abcdef\n")
        self.assertNotIn("example-token", out.stdout + out.stderr)
        self.shell("read_cf_credentials", "1\nexample-token\nbad-zone\n", status=1)

    def test_renewal_failure_is_not_reported_as_success(self):
        result = self.shell("require_ready() { :; }; acme() { return 7; }; renew_certificates", status=1)
        self.assertNotIn("续期检查完成", result.stdout)

    def test_revocation_failure_does_not_remove_data(self):
        self.make_certificate()
        self.shell("""
require_ready() { :; }; list_certificates() { :; }
acme() { printf '%s\\n' "$*" >> "$STATE_DIR/calls"; return 5; }
revoke_certificate
""", "example.com\nexample.com\n", status=1)
        self.assertNotIn("--remove", (self.path / "state/calls").read_text())
        self.assertTrue((self.path / "acme/example.com_ecc/example.com.conf").exists())

    def test_uninstall_requires_confirmation_and_keeps_certificates(self):
        self.make_certificate()
        out = self.shell('installed() { :; }; uninstall_manager', "n\n")
        self.assertIn("已取消", out.stdout)
        self.seed_cron()
        self.shell(self.cron_stub() + """
installed() { :; }
acme() { printf '%s\\n' "$*" >> "$STATE_DIR/calls"; }
uninstall_manager
""", "UNINSTALL\n")
        self.assertTrue((self.path / "acme/example.com_ecc/fullchain.cer").exists())
        self.assertIn("--uninstall --nocron", (self.path / "state/calls").read_text())

    def test_archive_traversal_and_symlinks_are_rejected(self):
        for kind in ("traversal", "symlink"):
            archive = self.path / "bad.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                item = tarfile.TarInfo("root/../../escape" if kind == "traversal" else "root/acme.sh")
                if kind == "symlink":
                    item.type = tarfile.SYMTYPE
                    item.linkname = "/etc/passwd"
                    tar.addfile(item)
                else:
                    item.size = 4
                    tar.addfile(item, io.BytesIO(b"evil"))
            self.shell(f"""
email=
download() {{
    if [[ "$1" == *releases/latest ]]; then echo '{{"tag_name":"3.1.6"}}' > "$2"
    else cp {q(str(archive))} "$2"; fi
}}
install_client
""", status=1)
            self.assertFalse((self.path / "escape").exists())

    def test_eof_and_zero_exit_cleanly(self):
        for data in ("", "0\n", "invalid\n0\n"):
            self.shell("menu", data)


if __name__ == "__main__":
    unittest.main()
