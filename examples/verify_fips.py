"""Verify a combined Java FIPS + Python FIPS hardened image.

Checks that both runtimes are present and that Python's crypto is backed by an
active OpenSSL FIPS provider. Run inside the customized image:

    docker run --rm <image> python3 verify_fips.py
"""
import os
import subprocess
import sys


def check(label, passed, detail=""):
    line = f"[{'PASS' if passed else 'FAIL'}] {label}"
    if detail:
        line += f": {detail}"
    print(line)
    return passed


def verify_python():
    return check("Python runtime", True, sys.version.split()[0])


def verify_pip():
    try:
        r = subprocess.run(["pip3", "--version"], capture_output=True, text=True)
        return check("pip3 available", r.returncode == 0,
                     r.stdout.strip() or r.stderr.strip())
    except FileNotFoundError:
        return check("pip3 available", False, "pip3 not on PATH")


def verify_java():
    try:
        # `java -version` prints to stderr by convention.
        r = subprocess.run(["java", "-version"], capture_output=True, text=True)
        # Skip JVM notices like "Picked up JAVA_TOOL_OPTIONS: ..." to find the
        # real version line (contains "version").
        lines = (r.stderr or r.stdout).splitlines()
        version = next((l for l in lines if "version" in l.lower()),
                       lines[0] if lines else "unknown")
        return check("Java runtime", r.returncode == 0, version)
    except FileNotFoundError:
        return check("Java runtime", False, "java not on PATH")


def verify_python_ssl():
    try:
        import ssl
        return check("Python ssl module", True, ssl.OPENSSL_VERSION)
    except Exception as e:  # noqa: BLE001
        return check("Python ssl module", False, str(e))


def verify_fips_provider():
    """Confirm Python's OpenSSL has the FIPS provider loaded/active."""
    try:
        import ssl
        # Python 3.12+ exposes get_default_verify_paths; for FIPS we probe the
        # provider via a hashlib call that is blocked in FIPS mode (md5) and one
        # that is allowed (sha256).
        import hashlib
        sha = hashlib.sha256(b"x").hexdigest()
        ok = bool(sha)
        try:
            hashlib.md5(b"x")  # FIPS mode disallows md5
            fips_active = False
            detail = "md5 allowed -> FIPS NOT enforced"
        except Exception as md5_err:  # ValueError / UnsupportedDigestmodError
            fips_active = True
            detail = f"md5 blocked ({type(md5_err).__name__}) -> FIPS enforced"
        return check("OpenSSL FIPS provider active", ok and fips_active,
                     f"{ssl.OPENSSL_VERSION}; {detail}")
    except Exception as e:  # noqa: BLE001
        return check("OpenSSL FIPS provider active", False, str(e))


def verify_openssl_conf():
    conf = os.environ.get("OPENSSL_CONF", "/etc/ssl/openssl.cnf")
    exists = os.path.isfile(conf)
    detail = conf
    if exists:
        try:
            with open(conf) as f:
                if "fips" in f.read().lower():
                    detail += " (references fips)"
        except OSError:
            pass
    return check("OpenSSL config present", exists, detail)


if __name__ == "__main__":
    print("=== Java FIPS + Python FIPS image verification ===\n")
    results = [
        verify_java(),
        verify_python(),
        verify_pip(),
        verify_python_ssl(),
        verify_openssl_conf(),
        verify_fips_provider(),
    ]
    print()
    passed = sum(results)
    print(f"Result: {passed}/{len(results)} checks passed")
    sys.exit(0 if all(results) else 1)
