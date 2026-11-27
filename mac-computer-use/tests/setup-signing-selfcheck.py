#!/usr/bin/env python3
"""Offline check of setup.py's signing identity choice: no keychain, codesign or openssl is run.

Several "Apple Development" identities: the installed app's team first, then MAC_CU_SIGNING_TEAM, then the first one
listed; one identity: that one; none: ad-hoc ("-").
"""
import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
script = Path(__file__).resolve().parents[1] / "skills/mac-computer-use/scripts/setup.py"
sys.path.insert(0, str(script.parent))
spec = importlib.util.spec_from_file_location("mac_cu_setup", script)
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)

FIRST, SECOND = "A" * 40, "B" * 40
TEAMS = {"FIRSTCERT": "TEAMONE001", "SECONDCERT": "TEAMTWO002"}


def fake(identities, installed_team=None):
    """subprocess.run stand-in answering security, codesign and openssl from the given state; records the calls."""
    calls = []

    def run(command, **kwargs):
        calls.append(command[0])
        out = err = ""
        if command[:2] == ["security", "find-identity"]:
            out = "".join(f'  {n}) {digest} "Apple Development: Someone ({digest[:4]})"\n' for n, digest in enumerate(identities, 1))
            out += f"     {len(identities)} valid identities found\n"
        elif command[:2] == ["security", "find-certificate"]:
            for digest, body in ((FIRST, "FIRSTCERT"), (SECOND, "SECONDCERT")):
                out += f"SHA-256 hash: {'0' * 64}\nSHA-1 hash: {digest}\n-----BEGIN CERTIFICATE-----\n{body}\n-----END CERTIFICATE-----\n"
        elif command[0] == "/usr/bin/openssl":
            body = kwargs["input"].splitlines()[1]
            out = f"subject=C=US,O=Someone,OU={TEAMS[body]},CN=Apple Development: Someone,UID=X\n"
        elif command[0] == "codesign":
            err = "Executable=/x\nIdentifier=com.kakao.mac-cu\n" + (f"TeamIdentifier={installed_team}\n" if installed_team else "TeamIdentifier=not set\n")
        else:
            raise AssertionError(f"unexpected command {command}")
        return subprocess.CompletedProcess(command, 0, out, err)
    return run, calls


def choose(identities, installed_team=None, environment=None, app=True):
    run, calls = fake(identities, installed_team)
    setup.subprocess.run = run
    with tempfile.TemporaryDirectory(prefix="mac-cu-signing-check-") as folder:
        bundle = Path(folder) / "mac-cu.app"
        if app:
            bundle.mkdir()
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            chosen = setup.signing_identity(bundle, environment or {})
    return chosen, calls, printed.getvalue()


original = subprocess.run
try:
    assert choose([])[0] == "-", "no identity: ad-hoc"
    chosen, calls, _ = choose([SECOND], installed_team="TEAMONE001")
    assert chosen == SECOND and calls == ["security"], "one identity: used as before, nothing else read"
    assert choose([FIRST, SECOND], installed_team="TEAMTWO002")[0] == SECOND, "installed app's team wins over list order"
    assert choose([FIRST, SECOND], installed_team="TEAMTWO002", environment={"MAC_CU_SIGNING_TEAM": "TEAMONE001"})[0] == SECOND, \
        "installed app's team wins over the variable"
    assert choose([FIRST, SECOND], app=False, environment={"MAC_CU_SIGNING_TEAM": "TEAMTWO002"})[0] == SECOND, \
        "no installed app: the variable's team"
    assert choose([FIRST, SECOND], installed_team=None, environment={"MAC_CU_SIGNING_TEAM": "TEAMTWO002"})[0] == SECOND, \
        "ad-hoc installed app: the variable's team"
    assert choose([FIRST, SECOND], installed_team="OTHERTEAM9", environment={"MAC_CU_SIGNING_TEAM": "TEAMTWO002"})[0] == SECOND, \
        "installed team without a certificate here: the variable's team"
    chosen, _, printed = choose([FIRST, SECOND], app=False, environment={"MAC_CU_SIGNING_TEAM": "NOSUCHTEAM"})
    assert chosen == FIRST and "NOSUCHTEAM" in printed, "unknown variable team: first identity, with a note"
    assert choose([FIRST, SECOND], app=False)[0] == FIRST, "nothing to follow: first identity (earlier behavior)"
    assert choose([SECOND, FIRST], app=False)[0] == SECOND, "nothing to follow: list order decides"

    # Helper build failure returns False and prints stderr instead of raising CalledProcessError.
    with tempfile.TemporaryDirectory(prefix="mac-cu-helper-fail-") as folder:
        temp_bundle = Path(folder) / "mac-cu.app"
        old_bundle, old_icon, old_view, old_run_swift = (
            setup.BUNDLE, setup.build_app_icon, setup.build_view_capture_resources, setup.run_swift
        )
        try:
            setup.BUNDLE = temp_bundle
            setup.build_app_icon = lambda _resources: True
            setup.build_view_capture_resources = lambda _dest: {}
            setup.run_swift = lambda cmd, **_kw: subprocess.CompletedProcess(cmd, 0, "", "")

            def fail_helper(command, **kwargs):
                if command[0] == "security":
                    return subprocess.CompletedProcess(command, 0, "0 valid identities found\n", "")
                if command[0] == "swiftc":
                    return subprocess.CompletedProcess(command, 1, "", "helper compile error: bad symbol\n")
                raise AssertionError(f"unexpected command after helper failure: {command}")

            setup.subprocess.run = fail_helper
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                ok = setup.build_app()
            assert ok is False and "helper compile error: bad symbol" in err.getvalue(), (ok, err.getvalue())
        finally:
            setup.BUNDLE = old_bundle
            setup.build_app_icon = old_icon
            setup.build_view_capture_resources = old_view
            setup.run_swift = old_run_swift
finally:
    setup.subprocess.run = original
print("Signing identity checks passed: none, one, installed team, variable team, fallbacks.")
