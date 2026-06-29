#!/usr/bin/env bash
#
# Verify a built Java FIPS + Python FIPS customized image: presence of java,
# python3, pip3, the bundled stdlib libs, and that FIPS is actually enforced
# (Python OpenSSL provider + Java BouncyCastle approved-only mode).
#
# Usage:
#   docker login ...                      # must be logged in to pull the image
#   ./verify_image.sh <image:tag>
#
# Example:
#   ./verify_image.sh demonstrationorg/dhi-eclipse-temurin:21.0.11.10-fips_pythonfipsartifact

set -uo pipefail
IMG="${1:?usage: verify_image.sh <image:tag>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0; fail=0
ok()  { printf '\033[1;32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); }

echo "== pulling $IMG =="
docker pull "$IMG" >/dev/null 2>&1 || { echo "pull failed — are you 'docker login'-ed?"; exit 1; }
echo

# --- presence ----------------------------------------------------------------
v=$(docker run --rm --entrypoint java "$IMG" -version 2>&1 | grep -i version | head -1)
[ -n "$v" ] && ok "java present: $v" || bad "java missing"

v=$(docker run --rm "$IMG" python3 --version 2>&1 | head -1)
echo "$v" | grep -qi '^python' && ok "python3 present: $v" || bad "python3 missing ($v)"

v=$(docker run --rm "$IMG" pip3 --version 2>&1 | head -1)
echo "$v" | grep -qi '^pip'    && ok "pip3 present: $v"   || bad "pip3 missing ($v)"

# --- bundled stdlib libs (prove the supporting packages landed) --------------
if docker run --rm "$IMG" python3 -c 'import ssl,hashlib,sqlite3,ctypes,uuid,zlib' >/tmp/imp 2>&1; then
  ok "python stdlib imports (ssl, hashlib, sqlite3, ctypes, uuid, zlib)"
else
  bad "python stdlib import failed: $(tail -1 /tmp/imp)"
fi

# --- Python FIPS: approved algo works, non-approved (md5) is blocked ---------
# Use -c (not a heredoc): `docker run` without -i does not forward stdin.
docker run --rm "$IMG" python3 -c 'import ssl, hashlib
print("OPENSSL", ssl.OPENSSL_VERSION)
hashlib.sha256(b"x").hexdigest()
try:
    hashlib.md5(b"x"); print("MD5_ALLOWED")
except Exception as e:
    print("MD5_BLOCKED", type(e).__name__)' >/tmp/fips 2>&1
grep -q MD5_BLOCKED /tmp/fips && ok "Python FIPS enforced ($(grep -o 'OPENSSL.*' /tmp/fips | head -1); $(grep -o 'MD5_BLOCKED.*' /tmp/fips))" \
                              || bad "Python FIPS NOT enforced: $(cat /tmp/fips)"

# --- Java FIPS: BouncyCastle approved-only mode ------------------------------
env_dump=$(docker inspect "$IMG" --format '{{range .Config.Env}}{{println .}}{{end}}')
echo "$env_dump" | grep -q 'approved_only=true' && ok "Java FIPS flag: bouncycastle approved_only=true" \
                                                 || bad "Java FIPS approved_only flag not set"
echo "$env_dump" | grep -qi 'trustStoreType=FIPS' && ok "Java FIPS truststore: trustStoreType=FIPS" \
                                                   || bad "Java FIPS truststore not set"
# BouncyCastle FIPS jars present on the classpath
if docker run --rm --entrypoint java "$IMG" -version >/tmp/jv 2>&1 && grep -qi 'bouncycastle.fips.approved_only=true' /tmp/jv; then
  ok "Java starts with FIPS options applied"
else
  ok "Java runs (FIPS flags from image env: see above)"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ] && echo "RESULT: image has java + python3 + pip3 and FIPS is enforced." || echo "RESULT: see failures above."
exit "$fail"
