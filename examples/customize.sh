#!/usr/bin/env bash
#
# Automated creation of the Java FIPS + Python FIPS DHI customizations.
#
# Handles the two gotchas this repo hit by hand:
#   * Artifact-based customizations require dhictl v0.0.2 — v0.0.3+ corrupts
#     artifact inputs with an invalid `__typename` field. This script pins and
#     auto-installs v0.0.2 into examples/.bin so artifacts always work.
#   * `create` fails if the customization already exists, so `recreate` does a
#     delete-then-create, and `edit` updates in place.
#
# Usage:
#   DOCKER_PAT=<hub-token> ./customize.sh <action> [target]
#
#   action : create | edit | recreate | discover   (default: create)
#   target : artifact | packages | all             (default: all)
#
# `discover` does not create anything — it prints the real tag-definition-ids
# available to your org for the Temurin source, so you can paste the FIPS one
# into the customization.yaml files (v0.0.2 requires the ID, not a tag name).
#
# Examples:
#   DOCKER_PAT=dckr_pat_xxx ./customize.sh discover
#   DOCKER_PAT=dckr_pat_xxx ./customize.sh create artifact
#   DOCKER_PAT=dckr_pat_xxx ./customize.sh recreate all
#
# Env overrides:
#   DHI_ORG          Docker Hub org           (default: demonstrationorg)
#   DHICTL_VERSION   pinned dhictl version    (default: v0.0.2 — needed for artifacts)
#   DOCKER_PAT       Docker Hub PAT           (required; dhictl auth)

set -euo pipefail

ORG="${DHI_ORG:-demonstrationorg}"
DHICTL_VERSION="${DHICTL_VERSION:-v0.0.2}"
ACTION="${1:-create}"
TARGET="${2:-all}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/.bin"
DHICTL="$BIN_DIR/dhictl"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- preconditions ------------------------------------------------------------
[ -n "${DOCKER_PAT:-}" ] || err "DOCKER_PAT is not set (export your Docker Hub token)."
case "$ACTION" in create|edit|recreate|discover) ;; *) err "unknown action '$ACTION' (create|edit|recreate|discover)";; esac
case "$TARGET" in artifact|packages|all) ;; *) err "unknown target '$TARGET' (artifact|packages|all)";; esac

TEMURIN_SOURCE="${TEMURIN_SOURCE:-eclipse-temurin}"   # DHI catalog slug (not "temurin")
TEMURIN_MAJOR="${TEMURIN_MAJOR:-21}"

# --- ensure pinned dhictl -----------------------------------------------------
ensure_dhictl() {
  if [ -x "$DHICTL" ] && "$DHICTL" -v 2>/dev/null | grep -q "$DHICTL_VERSION"; then
    log "dhictl $DHICTL_VERSION already present"
    return
  fi
  local os arch
  case "$(uname -s)" in Darwin) os=darwin;; Linux) os=linux;; *) err "unsupported OS $(uname -s)";; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64;; x86_64|amd64) arch=amd64;; *) err "unsupported arch $(uname -m)";; esac
  mkdir -p "$BIN_DIR"
  log "installing dhictl $DHICTL_VERSION ($os/$arch) -> $DHICTL"
  curl -fsSL "https://github.com/docker-hardened-images/dhictl/releases/download/${DHICTL_VERSION}/dhictl-${os}-${arch}" -o "$DHICTL"
  chmod +x "$DHICTL"
  [ "$os" = darwin ] && xattr -d com.apple.quarantine "$DHICTL" 2>/dev/null || true
  "$DHICTL" -v
}

# --- read name/destination straight from the yaml (no hardcoding) -------------
yaml_field() { sed -n "s/^${2}:[[:space:]]*//p" "$1" | head -1 | tr -d '"'; }

apply_one() {
  local dir="$1" file name dest repo
  file="$SCRIPT_DIR/$dir/customization.yaml"
  [ -f "$file" ] || err "missing $file"
  name="$(yaml_field "$file" name)"
  dest="$(yaml_field "$file" destination)"          # e.g. demonstrationorg/dhi-temurin
  repo="${dest#docker.io/}"
  log "[$dir] action=$ACTION name=$name destination=$repo"

  case "$ACTION" in
    create)
      "$DHICTL" customization create "$file" --org "$ORG"
      ;;
    edit)
      "$DHICTL" customization edit "$file" --org "$ORG"
      ;;
    recreate)
      # v0.0.2 delete takes a single customization name/ID (passing repo + name
      # is parsed as TWO targets). No --yes flag, so pipe a confirmation.
      yes | "$DHICTL" customization delete "$name" --org "$ORG" 2>/dev/null \
        || log "no existing '$name' to delete, continuing"
      "$DHICTL" customization create "$file" --org "$ORG"
      ;;
  esac
  log "[$dir] done. Monitor builds with:"
  echo "    $DHICTL customization build list $repo $name --org $ORG"
}

# --- discover: print real tag-definition-ids for the Temurin source ----------
discover() {
  log "tag-definition-ids for source '$TEMURIN_SOURCE' (look for the FIPS one):"
  # `prepare` generates a scaffold whose tag_definition_id is the canonical ID.
  # Try the catalog listing first; fall back to prepare's generated yaml.
  "$DHICTL" catalog get "$TEMURIN_SOURCE" --org "$ORG" 2>/dev/null \
    || log "catalog get unavailable on this version; trying prepare"
  echo
  log "scaffold (its tag_definition_id is the value to paste into the yaml files):"
  "$DHICTL" customization prepare "$TEMURIN_SOURCE" "$TEMURIN_MAJOR" --org "$ORG"
  echo
  log "If the scaffold shows a non-FIPS tag, re-run prepare with the FIPS tag, e.g.:"
  echo "    $DHICTL customization prepare $TEMURIN_SOURCE ${TEMURIN_MAJOR}-debian13-fips --org $ORG"
}

# --- run ----------------------------------------------------------------------
ensure_dhictl
export DOCKER_PAT

if [ "$ACTION" = discover ]; then
  discover
  exit 0
fi

case "$TARGET" in
  artifact) apply_one 01-artifact-bundle ;;
  packages) apply_one 02-packages ;;
  all)      apply_one 01-artifact-bundle; apply_one 02-packages ;;
esac

log "all requested customizations processed."
