# DHI Python Customization

A Docker Hardened Image (DHI) customization that extends the official `dhi/python:3.14` (Alpine 3.23) image with:

- Additional hardened packages: `curl`
- BusyBox binaries from `demonstrationorg/dhi-busybox:1-alpine3.23` (injected into `/bin`)
- Zscaler root CA certificate injected into the system trust store (`/etc/ssl/certs/ca-certificates.crt`)

The resulting image is published to `docker.io/demonstrationorg/dhi-python`.

---

## Project Structure

```
.
├── customization.yaml      # DHI customization definition (source of truth)
├── Dockerfile              # Local Dockerfile using the customized DHI image
├── Dockerfile.certs        # Builds the OCI artifact containing the Zscaler CA bundle
├── certs/
│   └── zscaler.crt         # Zscaler root CA certificate (PEM format)
└── main.py                 # Sample Python application
```

---

## Prerequisites

- Docker Desktop with DHI access enabled
- `dhictl` CLI — see [DHI CLI reference](https://docs.docker.com/dhi/how-to/cli/)
- Access to your Docker Hub organization
- GitHub repository variable `DHI_ORG` set to your Docker Hub org name

---

## Step 1 — Build and push the Zscaler cert artifact

The Zscaler certificate is packaged as an OCI artifact and referenced by the customization. Build and push it before applying the customization:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t demonstrationorg/zscaler-cert:latest \
  --push \
  -f Dockerfile.certs .
```

To verify the cert was included correctly:

```bash
docker run --rm demonstrationorg/zscaler-cert:latest \
  /bin/bash -c "grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt"
```

> The `demonstrationorg/dhi-busybox:1-alpine3.23` artifact is pulled directly from Docker Hub by the DHI build service — no separate build step required.

---

## Step 2 — Apply the customization

Two GitHub Actions workflows handle the customization lifecycle:

| Workflow | Trigger | Purpose |
|---|---|---|
| **DHI Customization Recreate** | Manual (`workflow_dispatch`) | Deletes the existing customization, creates it fresh, and commits the assigned ID back to `customization.yaml` |
| **DHI Customization Edit** | Push to `main` when `customization.yaml` changes, or manual with version inputs | Updates an existing customization (requires `id` in the yaml) |

**First-time setup — run the Recreate workflow:**

Go to **Actions → DHI Customization Recreate → Run workflow**. It will:
1. Delete any existing customization
2. Create it from `customization.yaml`
3. Retrieve the assigned ID via `dhictl customization list --org demonstrationorg | grep zscaler`
4. Commit the ID back to `customization.yaml` automatically

**Updating versions — run the Edit workflow:**

Go to **Actions → DHI Customization Edit → Run workflow** and optionally provide:
- `busybox_version` — e.g. `1.38.0-alpine3.23`
- `zscaler_cert_tag` — e.g. `v2`

Leave blank to resubmit the current `customization.yaml` unchanged.

Monitor the build:

```bash
# List builds to get a build ID
dhictl customization build list demonstrationorg/dhi-python zscaler --org demonstrationorg

# Stream logs for a specific build
dhictl customization build logs demonstrationorg/dhi-python zscaler <build-id> --org demonstrationorg
```

For full details on the customization workflow, see [How to customize a DHI image](https://docs.docker.com/dhi/how-to/customize/).

---

## Step 3 — Use the customized image

Once the build completes, pull the image:

```bash
docker pull demonstrationorg/dhi-python:3.14.3-alpine3.23_zscaler
```

> This image has no shell. Use [`docker debug`](https://docs.docker.com/reference/cli/docker/debug/) to inspect it interactively — it attaches a debugging toolkit without modifying the image.

```bash
docker debug demonstrationorg/dhi-python:3.14.3-alpine3.23_zscaler
```

Inside the debug shell:

```bash
# Verify the Zscaler cert is present
grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt

# Verify BusyBox binaries
ls /bin

# Check curl
curl --version

# Check Python
python3 --version
```

**Run the verification app** (`main.py` checks Python, SSL cert bundle, curl, and BusyBox binaries):

```bash
docker build -t dhi-python-verify .
docker run --rm dhi-python-verify
```

Expected output:
```
=== DHI Python Customization Verification ===

[PASS] Python version: 3.14.x
[PASS] SSL_CERT_FILE points to existing file: /etc/ssl/certs/ca-certificates.crt
[PASS] CA bundle certificate count: 148
[PASS] curl available: curl x.x.x ...
[PASS] BusyBox /bin/sh
[PASS] BusyBox /bin/ls
[PASS] BusyBox /bin/cat

Result: 7/7 checks passed
```

---

## Regenerating the customization scaffold

If you need to regenerate `customization.yaml` from scratch:

```bash
dhictl customization prepare python 3.14 \
  --org demonstrationorg \
  --destination demonstrationorg/dhi-python \
  --name "zscaler" \
  --output customization.yaml
```

Then re-add the packages and artifact entries under `contents:`.
