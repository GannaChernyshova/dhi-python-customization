import os
import subprocess
import sys


def check(label, passed, detail=""):
    status = "PASS" if passed else "FAIL"
    line = f"[{status}] {label}"
    if detail:
        line += f": {detail}"
    print(line)
    return passed


def verify_python():
    return check("Python version", True, sys.version.split()[0])


def verify_ssl_cert_file():
    cert_file = os.environ.get("SSL_CERT_FILE", "")
    exists = bool(cert_file) and os.path.isfile(cert_file)
    return check("SSL_CERT_FILE points to existing file", exists, cert_file)


def verify_zscaler_cert():
    cert_file = os.environ.get("SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt")
    try:
        with open(cert_file) as f:
            contents = f.read()
        count = contents.count("BEGIN CERTIFICATE")
        return check("CA bundle certificate count", count > 0, str(count))
    except OSError as e:
        return check("CA bundle readable", False, str(e))


def verify_curl():
    try:
        result = subprocess.run(["curl", "--version"], capture_output=True, text=True)
        version = result.stdout.splitlines()[0] if result.stdout else "unknown"
        return check("curl available", result.returncode == 0, version)
    except FileNotFoundError:
        return check("curl available", False, "not found in PATH")


def verify_busybox():
    busybox_bins = ["sh", "ls", "cat"]
    results = []
    for binary in busybox_bins:
        path = f"/bin/{binary}"
        exists = os.path.isfile(path)
        results.append(check(f"BusyBox /bin/{binary}", exists))
    return all(results)


if __name__ == "__main__":
    print("=== DHI Python Customization Verification ===\n")

    results = [
        verify_python(),
        verify_ssl_cert_file(),
        verify_zscaler_cert(),
        verify_curl(),
        verify_busybox(),
    ]

    print()
    total = len(results)
    passed = sum(results)
    print(f"Result: {passed}/{total} checks passed")

    sys.exit(0 if all(results) else 1)
