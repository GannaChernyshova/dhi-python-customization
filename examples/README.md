# Java FIPS + Python FIPS — DHI customization examples

Two ways to produce a single Docker Hardened Image that runs **both** an
OpenJDK (Temurin) FIPS runtime and a Python FIPS runtime, starting from
`demonstrationorg/dhi-temurin:21-debian13-fips`.

Both examples keep **Temurin as the base image on purpose**: the Java FIPS
posture (the JDK's `java.security` provider config and the base's
FIPS-validated OpenSSL) is preserved automatically when you only *add* on top of
it. Python is then layered in two different ways.

| | Example 1 — Artifact bundle | Example 2 — Hardened packages |
|---|---|---|
| Folder | [`01-artifact-bundle/`](01-artifact-bundle/customization.yaml) | [`02-packages/`](02-packages/customization.yaml) |
| How Python is added | Copy the `dhi-python-ann:3.14-debian13-fips` image in as an **OCI artifact** | Install `python3` + `python3-pip` from the **DHI hardened package repo** |
| Customization `name` | `pythonFipsArtifact` | `pythonFipsPackages` |
| Destination (existing Temurin mirror) | `demonstrationorg/dhi-temurin` | `demonstrationorg/dhi-temurin` |
| Output tag | `21-debian13-fips_pythonFipsArtifact` | `21-debian13-fips_pythonFipsPackages` |
| FIPS crypto chain | ⚠️ Must be preserved by hand (see below) | ✅ Shared with the base automatically |
| Python version control | Pinned by the artifact tag (`3.14`) | Whatever the hardened repo ships for this base |
| Recommended when | You need an exact Python build, extra site-packages baked in, or files the package doesn't provide | You just need `python3`/`pip3` on a Java FIPS base — **the default choice** |

---

## Do I need to include/exclude specific paths from the Python image? (Example 1)

**Yes — and this is the most important part of the artifact approach.**

`includes` is an **allow-list**: an artifact contributes *nothing* unless you
list paths. `excludes` is applied afterwards to subtract from what `includes`
matched.

### Include — must be a recursive glob `opt/**`

> **Gotcha (verified the hard way):** the DHI customization artifact include
> requires a **recursive glob**. A bare directory path copies the directory entry
> only and recurses **nothing** — the result image ends up with no python at all.
>
> ```yaml
> includes:
>   - opt/**          # ✅ copies the whole /opt tree (python symlink + real runtime)
> # - opt/python      # ❌ copies nothing usable
> # - opt/python-3.14.6  # ❌ also copies nothing (bare dir does not recurse)
> ```
>
> This matches DHI's own catalog, where the Python image is assembled with
> `includes: [opt/**]`. `opt/**` brings the `/opt/python` symlink, the real
> `/opt/python-3.14.x/` runtime (python3, pip3, libpython, stdlib, site-packages),
> and `/opt/docker` (which just overwrites the base's static SBOM dir — harmless;
> the build regenerates the real SBOM attestation). It also avoids hard-coding the
> Python patch version.

This pulls **both python3 and pip3 from the Python image**. Because both images
are **Debian 13** based, the glibc ABI matches and the binaries run on the Temurin
base. **Verified end-to-end** on the built image: `python3` = 3.14.6, `pip3` =
26.1.2, and `import ssl,sqlite3,ctypes,uuid,zlib` all succeed.

> **Build-cache caveat:** the DHI build service caches the artifact "copy" layer
> per customization **id** (deterministic from name+destination). If a name was
> ever built with a broken (bare-path) include, edits won't bust that cache — you
> must create under a **new name** to get a clean build.

### Supporting libraries (added as `packages`, not from the artifact)

The interpreter and pip come from the artifact, but Python's C-extension modules
link against system shared libraries that the **Temurin JRE base does not ship**
(it has only `base-files`, `ca-certificates`, `libstdc++6`, `locales`). Without
them the copied `python3` imports fine but fails on `sqlite3`, `ctypes`, etc.

The example adds a **minimal set** via `contents.packages`, drawn from the same
hardened Debian 13 repo the Python image uses (so they are ABI-matched):
`zlib1g` (pip/wheels), `libffi8` (`ctypes`), `libsqlite3-0` (`sqlite3`),
`libuuid1` (`uuid`), `netbase` (socket lookups). If your app needs more, add the
matching lib from the Python image's fuller set: `libbz2-1.0` (`bz2`),
`liblzma5` (`lzma`), `libreadline8t64`+`libncursesw6`+`ncurses-base/bin`
(`readline`/`curses`), `libcrypt1` (`crypt`), `libdb5.3t64` (`dbm`), `tzdata`
(`zoneinfo`). The FIPS OpenSSL (`libssl`/`libcrypto` + `fips.so`) already ships
in the `-fips` Temurin base, so you do **not** copy OpenSSL across.

### Exclude — not needed here (and omitted on purpose)

Because `includes` is an allow-list, listing only `opt/python` already means
nothing else is copied, so **no `excludes` are required**. The example omits
them for a second reason too: dhictl **v0.0.5** mis-serializes any artifact that
carries an `excludes` field, injecting an invalid `__typename` into the create
mutation (`Field "__typename" is not defined by type "DhiCustomizationArtifactInput"`).

You only need `excludes` if you widen `includes` beyond `opt/python`. In that
case, never copy these from the Python image:

- **`etc/passwd`, `etc/group`, `etc/shadow`** — would clobber the `nonroot`
  accounts defined in `accounts:`.
- **`etc/os-release`** — OS identity belongs to the Temurin base.
- **`etc/ssl/openssl.cnf`, `etc/ssl/fipsmodule.cnf`** — **keep the Temurin
  base's FIPS OpenSSL configuration.** Pulling Python's copies risks pointing
  OpenSSL at a different module path and silently dropping out of FIPS mode.

> **FIPS caveat for the artifact approach.** Copying a pre-built Python in means
> its `_ssl`/`_hashlib` extensions must resolve to the base's FIPS-validated
> OpenSSL at runtime. Verify this after the build (see below). If Python instead
> loads a bundled OpenSSL from `/opt/python/lib`, your FIPS validation boundary
> is no longer the one you certified. Example 2 avoids this entirely.

---

## Build & apply

**Prerequisites**

- **dhictl version matters for the artifact example.** dhictl **>= v0.0.3**
  has a bug that injects an invalid `__typename` field into every artifact
  input, so `create`/`edit` of Example 1 fails with
  `Field "__typename" is not defined by type "DhiCustomizationArtifactInput"`.
  Use **dhictl v0.0.2** for the artifact example (it's the version the repo's CI
  uses and what built the existing busybox/zscaler artifact customization).
  Example 2 (packages, no artifacts) is unaffected and works on any version.
  ```bash
  ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
  curl -fsSL "https://github.com/docker-hardened-images/dhictl/releases/download/v0.0.2/dhictl-darwin-${ARCH}" \
    -o "$(command -v dhictl)" && chmod +x "$(command -v dhictl)"
  xattr -d com.apple.quarantine "$(command -v dhictl)" 2>/dev/null
  dhictl -v   # should print v0.0.2
  ```
- **Schema is the flat form** (`source`/`destination`/`tag_definition_id`)
  because v0.0.2 predates the newer `targets:` array. The flat form still works
  on newer dhictl too (with a deprecation warning), so it's universal.
- `destination` must be an **existing DHI mirror** in your org. Mirror the
  Temurin image first (via Docker Hub UI or `dhictl`) so `demonstrationorg/dhi-temurin`
  exists — otherwise `create` fails with `no mirror found`. The customization
  adds new suffixed *tags* to that mirror; it does not create a new repo.
- `tag_definition_id` is set to the literal tag name `21-debian13-fips`. FIPS
  tags are entitlement-gated and do not appear in the public DHI catalog
  (the catalog's `eclipse-temurin/debian-13` exposes only non-FIPS tags), so the
  field uses the actual tag name in your mirror rather than a path-style ID.
  The source/image slug is `eclipse-temurin` (not `temurin`). If v0.0.2 rejects
  the tag name, list the exact definition IDs available to your org with:
  ```bash
  dhictl customization prepare eclipse-temurin 21 --org demonstrationorg
  ```

### Method A — Docker Hub web UI (recommended for the artifact example)

This is the officially documented flow and it does **not** hit the dhictl
artifact bug, because it never serializes through the broken CLI. Adding a
runtime via OCI artifact is exactly the documented use case
("add… another image that contains a tool you need, like adding Python to a
Node.js image"). Steps, with our `pythonFipsArtifact` values mapped in:

1. Docker Hub → **My Hub** → select your org (`demonstrationorg`).
2. **Hardened Images → Manage → Mirrored Images**.
3. On `dhi-eclipse-temurin`, menu icon → **Customize**.
4. Select the version **`21-debian13-fips`** → **Next**.
5. **Add packages** (minimal set): `zlib1g`, `libffi8`, `libsqlite3-0`,
   `libuuid1`, `netbase`. Add more from the Python image's dependency set only
   if your app needs them (see "Supporting libraries" above).
6. **Add OCI artifacts**: repository `dhi-python-ann`, tag `3.14-debian13-fips`;
   under include paths add **`opt/python`** (leave excludes empty). This is what
   brings **python3 + pip3** in from the Python image.
7. **Next: Configure** →
   - Environment: `PATH=/opt/python/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`,
     `LD_LIBRARY_PATH=/opt/python/lib`, `PYTHON_VERSION=3.14`.
   - Run-as user: `nonroot`. CMD: `java -version` (or `python3`).
   - Customization name suffix: `pythonFipsArtifact`. Platforms: amd64 + arm64.
8. **Review → Create Customization**.

The `customization.yaml` in this folder is the CLI equivalent of those choices —
keep it as the source-of-truth record even if you create via the UI.

### Method B — dhictl CLI

Reuses the repo-root lifecycle (dhictl + the two GitHub Actions workflows):

```bash
# From the example folder:
dhictl customization create customization.yaml --org demonstrationorg
# ...or update an existing one:
dhictl customization edit  customization.yaml --org demonstrationorg
```

> The **artifact example requires dhictl v0.0.2** (see the version note above —
> v0.0.3+ corrupts artifact inputs). The **packages example works on any
> version.** If a tag/package name is rejected, confirm the exact values with
> `dhictl customization prepare eclipse-temurin 21 --org demonstrationorg`.

### Method C — automated (script + GitHub Actions)

[`customize.sh`](customize.sh) automates both examples and handles the gotchas
for you: it auto-installs the **pinned dhictl v0.0.2** into `examples/.bin`
(so artifacts always work), reads `name`/`destination` from each yaml, and
supports create / edit / recreate.

```bash
# create | edit | recreate   and   artifact | packages | all
DOCKER_PAT=dckr_pat_xxx ./customize.sh recreate all
DOCKER_PAT=dckr_pat_xxx ./customize.sh create  artifact
```

CI: [`.github/workflows/fips-customizations.yml`](../.github/workflows/fips-customizations.yml)
runs the same script on **workflow_dispatch** (pick action + target) or on push
when an example's `customization.yaml` / `customize.sh` changes. It authenticates
with the `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` repo secrets, same as the
existing root workflows.

---

## Verify

The image has no shell. Inspect interactively with `docker debug`, or run the
included [`verify_fips.py`](verify_fips.py), which checks Java, Python, pip3,
and that Python's OpenSSL **FIPS provider is active** (it confirms `md5` is
blocked while `sha256` works):

```bash
docker run --rm \
  -v "$PWD/verify_fips.py:/verify_fips.py:ro" \
  demonstrationorg/dhi-temurin:21-debian13-fips_pythonFipsArtifact \
  python3 /verify_fips.py
```

Expected:

```
=== Java FIPS + Python FIPS image verification ===

[PASS] Java runtime: openjdk version "21..."
[PASS] Python runtime: 3.14.x
[PASS] pip3 available: pip 24.x ...
[PASS] Python ssl module: OpenSSL 3.x ...
[PASS] OpenSSL config present: /etc/ssl/openssl.cnf (references fips)
[PASS] OpenSSL FIPS provider active: OpenSSL 3.x ...; md5 blocked -> FIPS enforced

Result: 6/6 checks passed
```
