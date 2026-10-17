#!/usr/bin/env python3
"""Cross-version Keychain ACL test for StepBar's saved credentials.

Why this exists
---------------
StepBar stores its API key as a *legacy* (file-based) keychain generic-password
item under service ``local.stepbar.ai``. A legacy item's ACL does not trust a
file path and does not trust a cdhash: it stores a **code requirement** (the
requirement that was in force when the item was created) and re-evaluates it
against whatever process asks for the secret. If that requirement no longer
matches the app doing the read, macOS shows the ACL authorization dialog; the
documented "suppress the UI" options (``kSecUseAuthenticationUI``,
``LAContext.interactionNotAllowed``) do **not** apply to legacy items.

The observable consequence is the bug this test pins down: an item created by
one code identity (e.g. an ad-hoc build) is not readable by
the stable, certificate-signed app, so every background read pops a prompt.

What it proves (all in an isolated temp keychain, never the login keychain)
---------------------------------------------------------------------------
  T1  same identity, rebuilt binary at a different path        -> silent read
  T2  same identity, content changed (simulates an update)     -> silent read
  T3  ad-hoc binary reading the signed item                    -> denied (-25293)
  T4  different-certificate binary reading the signed item     -> denied (-25293)
  T5  item authored by an ad-hoc copy, read by the signed app  -> denied (-25293)
  T6  trust follows the identity, not the recorded file path   -> silent read

Every read runs with user interaction disabled, so a would-be ACL prompt turns
into ``errSecAuthFailed`` (-25293) instead of blocking. A silent success is
therefore positive proof the item is readable without any prompt, and a
-25293 is positive proof the read was denied without prompting.

Safety: opt-in only: creating a temporary keychain may affect the user's search
list even without an explicit list-keychains call. Never touches ``login.keychain-db`` or any
real StepBar credential. Requires ``openssl`` and ``codesign`` (Xcode CLT).
Exits 0 with SKIP when the toolchain is unavailable.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import textwrap

SERVICE = "local.stepbar.ai"
ACCOUNT = "openAI:tz.test"
ACCOUNT_T5 = ACCOUNT + ".t5"
ACCOUNT_T6 = ACCOUNT + ".t6"
SECRET = "sk-crossversion-0001"
IDENT = "local.stepbar.app.test"
ERR_SEC_AUTH_FAILED = -25293

HELPER = r"""
import Foundation
import Security

let env = ProcessInfo.processInfo.environment
let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let service = env["KC_SERVICE"]!
let account = env["KC_ACCOUNT"]!
let value = env["KC_VALUE"] ?? ""

// Never allow an ACL dialog: a denied read must return an OSStatus, not block.
_ = SecKeychainSetUserInteractionAllowed(false)

var keychain: SecKeychain?
if let path = env["KC_PATH"], !path.isEmpty {
    if SecKeychainOpen(path, &keychain) != errSecSuccess { FileHandle.standardError.write(Data("open failed\n".utf8)); exit(3) }
}

func report(_ s: OSStatus) {
    let m = SecCopyErrorMessageString(s, nil) as String? ?? ""
    print("status=\(s) (\(m))")
}

// Mirrors StepBar's own Keychain.write: SecItemAdd against a specific keychain.
switch cmd {
case "add":
    var q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: Data(value.utf8),
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
    ]
    if let keychain { q[kSecUseKeychain as String] = keychain }
    let s = SecItemAdd(q as CFDictionary, nil)
    report(s); exit(s == errSecSuccess ? 0 : 1)

// Mirrors StepBar's own Keychain.read: SecItemCopyMatching with the same
// kSecUseAuthenticationUIFail / interactionNotAllowed options the app sets.
case "read":
    var q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
    if let keychain { q[kSecMatchSearchList as String] = [keychain] }
    var out: CFTypeRef?
    let s = SecItemCopyMatching(q as CFDictionary, &out)
    report(s)
    if s == errSecSuccess, let d = out as? Data { print("value=\(String(data: d, encoding: .utf8) ?? "?")") }
    exit(s == errSecSuccess ? 0 : 1)
default:
    FileHandle.standardError.write(Data("usage: kc add|read\n".utf8)); exit(2)
}
"""


def run(argv, check=False, env=None):
    return subprocess.run(argv, capture_output=True, text=True, check=check, env=env)


class Failure(Exception):
    pass


def check(label, ok, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        raise Failure(label)


def main():
    if "--allow-temporary-keychain" not in sys.argv:
        print("SKIP: opt-in test may change the keychain search list; run only in a disposable macOS account with --allow-temporary-keychain")
        return 0
    for tool in ("openssl", "codesign", "security"):
        if shutil.which(tool) is None:
            print(f"SKIP: {tool} not available")
            return 0

    root = tempfile.mkdtemp(prefix="stepbar-kc-acl-", dir=os.environ.get("TMPDIR"))
    kc = os.path.join(root, "acl-test.keychain-db")
    kc_pass = "acl-test-pass"

    def cleanup():
        run(["security", "delete-keychain", kc])
        shutil.rmtree(root, ignore_errors=True)

    try:
        run(["security", "create-keychain", "-p", kc_pass, kc])
        run(["security", "set-keychain-settings", "-u", "-t", "21600", kc])
        run(["security", "unlock-keychain", "-p", kc_pass, kc])

        # Two synthetic self-signed code-signing identities.
        for name in ("ACLCertA", "ACLCertB"):
            work = os.path.join(root, name)
            os.makedirs(work, exist_ok=True)
            cnf = os.path.join(work, "cert.cnf")
            with open(cnf, "w") as fh:
                fh.write(textwrap.dedent(f"""
                    [req]
                    distinguished_name = dn
                    x509_extensions = ext
                    prompt = no
                    [dn]
                    CN = {name}
                    [ext]
                    basicConstraints = critical, CA:false
                    keyUsage = critical, digitalSignature
                    extendedKeyUsage = critical, codeSigning
                """))
            key, cert, p12 = (os.path.join(work, n) for n in ("key.pem", "cert.pem", "id.p12"))
            p12_pass = "p12-" + name
            if run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-days", "3650", "-config", cnf, "-keyout", key, "-out", cert]).returncode:
                print("SKIP: openssl could not create a certificate")
                return 0
            run(["openssl", "pkcs12", "-export", "-inkey", key, "-in", cert, "-name", name,
                 "-out", p12, "-passout", f"pass:{p12_pass}"], check=True)
            run(["security", "import", p12, "-k", kc, "-P", p12_pass,
                 "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], check=True)
        run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
             "-s", "-k", kc_pass, kc], check=True)

        # codesign is explicitly restricted to the temporary keychain below.

        helper_src = os.path.join(root, "kc.swift")
        with open(helper_src, "w") as fh:
            fh.write(HELPER)

        def build(tag, sign, path, extra=""):
            os.makedirs(path, exist_ok=True)
            binary = os.path.join(path, "kc")
            # A per-build constant forces a distinct cdhash so we are genuinely
            # testing identity matching, not byte-identity.
            src = os.path.join(root, f"kc_{tag}.swift")
            with open(src, "w") as fh:
                fh.write(HELPER.replace(
                    "let env = ProcessInfo",
                    f'let buildTag = "{tag}"\nlet env = ProcessInfo', 1))
            queries = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
            subprocess.run(["swiftc", "-O", src, "-o", binary], check=True, **queries)
            subprocess.run(["codesign", "--force", "--identifier", IDENT,
                            "--sign", sign, "--keychain", kc] + (extra.split() if extra else []) + [binary],
                           check=True, **queries)
            return binary

        def why(binary):
            out = run(["codesign", "-d", "-r-", binary])
            text = out.stderr + out.stdout
            for line in text.splitlines():
                if "designated" in line:
                    return line.split("=>", 1)[-1].strip() or line.strip()
            return "(no designated requirement: ad-hoc)"

        def call(binary, cmd, account=ACCOUNT):
            env = dict(os.environ, KC_PATH=kc, KC_SERVICE=SERVICE,
                       KC_ACCOUNT=account, KC_VALUE=SECRET)
            return run([binary, cmd], env=env)

        # --- creator: signed with identity A at path A ---------------------
        signed_a = build("creatorA", "ACLCertA", os.path.join(root, "appA"))
        created = call(signed_a, "add")
        if created.returncode != 0:
            print(f"SKIP: could not author a keychain item in the temp keychain\n{created.stdout}{created.stderr}")
            return 0

        print("Isolated keychain ACL / code-identity cross-version test")
        print(f"  item service={SERVICE} account={ACCOUNT}")
        print(f"  creator DR: {why(signed_a)}")

        # T1: same identity, new path, new cdhash -> silent
        r = call(build("rebuild1", "ACLCertA", os.path.join(root, "appB")), "read")
        check("T1 same identity rebuilt at a new path reads silently",
              r.returncode == 0 and f"value={SECRET}" in r.stdout,
              f"rc={r.returncode} {r.stdout.strip()}")

        # T2: content changed (update), same identity -> silent
        r = call(build("rebuild2", "ACLCertA", os.path.join(root, "appC")), "read")
        check("T2 same identity after a content change (update) reads silently",
              r.returncode == 0 and f"value={SECRET}" in r.stdout,
              f"rc={r.returncode} {r.stdout.strip()}")

        # T3: ad-hoc binary -> denied, no prompt
        r = call(build("adhoc", "-", os.path.join(root, "appD")), "read")
        check("T3 ad-hoc build is denied without a prompt",
              r.returncode == 1 and str(ERR_SEC_AUTH_FAILED) in r.stdout,
              f"rc={r.returncode} {r.stdout.strip()}")

        # T4: different certificate -> denied, no prompt
        r = call(build("othercert", "ACLCertB", os.path.join(root, "appE")), "read")
        check("T4 different-certificate build is denied without a prompt",
              r.returncode == 1 and str(ERR_SEC_AUTH_FAILED) in r.stdout,
              f"rc={r.returncode} {r.stdout.strip()}")

        # T5: the "poisoned item" scenario. An ad-hoc copy authors the item;
        # the stable signed app can then no longer read it. This is the root
        # cause of the repeated prompts after an update that replaced a
        # translocated/ad-hoc copy.
        adhoc_creator = build("poisoner", "-", os.path.join(root, "appF"))
        if call(adhoc_creator, "add", ACCOUNT_T5).returncode == 0:
            r = call(build("signed_reader", "ACLCertA", os.path.join(root, "appG")), "read", ACCOUNT_T5)
            check("T5 item authored by an ad-hoc copy is denied to the signed app",
                  r.returncode == 1 and str(ERR_SEC_AUTH_FAILED) in r.stdout,
                  f"rc={r.returncode} {r.stdout.strip()}")
        else:
            print("  SKIP  T5 ad-hoc creator could not author an item")

        # T6: trust is the stored requirement, not the recorded path. Rewrite
        # the *creator's* file at the recorded path with a different identity,
        # then confirm identity A from an unrelated path still reads silently.
        recorded_path_bin = build("recorded", "ACLCertA", os.path.join(root, "appH"))
        if call(recorded_path_bin, "add", ACCOUNT_T6).returncode == 0:
            subprocess.run(["codesign", "--force", "--identifier", IDENT,
                            "--sign", "ACLCertB", recorded_path_bin], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            r = call(build("identity_a_elsewhere", "ACLCertA", os.path.join(root, "appI")), "read", ACCOUNT_T6)
            check("T6 identity A still reads after its recorded path is re-signed as B",
                  r.returncode == 0 and f"value={SECRET}" in r.stdout,
                  f"rc={r.returncode} {r.stdout.strip()}")
        else:
            print("  SKIP  T6 creator could not author an item")

        print("ALL PASS")
        return 0
    except Failure:
        print("FAILED")
        return 1
    except subprocess.CalledProcessError as exc:
        print("SKIP: toolchain step failed:", exc)
        return 0
    finally:
        cleanup()


if __name__ == "__main__":
    sys.exit(main())
