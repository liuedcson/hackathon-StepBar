"""Exercise the shipped helper in an isolated directory with fake OS tools."""
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="stepbar-helper-tests-", dir=os.environ.get("TMPDIR")) as temporary:
    base = pathlib.Path(temporary)
    tools = base / "tools"
    tools.mkdir()
    commands = {
        "open": '#!/bin/zsh\necho launch >> "$HOME/launches"\n[[ "${FAIL_OPEN:-0}" != 1 ]]\n',
        "codesign": '#!/bin/zsh\n[[ "${FAIL_SIGN:-0}" != 1 ]]\n',
        "ditto": '#!/bin/zsh\n/bin/cp -R "$1" "$2"\n',
    }
    helper = (root / "scripts/install-update.sh").read_text()
    for name, content in commands.items():
        tool = tools / name
        tool.write_text(content)
        tool.chmod(0o700)
        helper = helper.replace("/usr/bin/" + name, str(tool))
    executable = base / "helper.sh"
    executable.write_text(helper.replace("{1..60}", "{1..2}"))
    for scenario in ("success", "signature-failure", "launch-failure", "running-translocated"):
        case = base / scenario
        case.mkdir()
        home = case / "home"
        home.mkdir()
        target = case / "StepBar.app"
        target.mkdir()
        (target / "version").write_text("old")
        workspace = case / "stepbar-update-test"
        source = workspace / "StepBar.app"
        source.mkdir(parents=True)
        (source / "version").write_text("new")
        env = dict(os.environ, HOME=str(home), FAIL_SIGN=str(int(scenario == "signature-failure")), FAIL_OPEN=str(int(scenario == "launch-failure")))
        sleeper = subprocess.Popen(["/bin/sleep", "20"]) if scenario == "running-translocated" else None
        try:
            result = subprocess.run(["/bin/zsh", str(executable), str(sleeper.pid) if sleeper else "99999999", str(source), str(target), str(workspace)], env=env, timeout=15)
        finally:
            if sleeper: sleeper.terminate(); sleeper.wait()
        assert (result.returncode == 0) == (scenario == "success"), scenario
        assert (target / "version").read_text() == ("new" if scenario == "success" else "old"), scenario
        assert not workspace.exists(), scenario
        assert not list(case.glob("StepBar.app.update-backup-*")), scenario
        assert (home / "launches").exists() == (scenario != "running-translocated"), scenario
        assert (home / "Library/Application Support/StepBar/update.log").exists(), scenario
    print("PASS: isolated helper replacement, rollback, cleanup, logs and live PID with different path blocks replacement")
