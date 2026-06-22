#!/usr/bin/env bash
# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD
#
# Vendor a controller's CRDs into its chart at the given image version, so the
# chart's CRDs and the image it deploys move together. Run by the appVersion
# bump PR (.github/workflows/bump.yml); also runnable by hand:
#
#   hack/vendor-crds.sh ghcr.io/metio/jaas 2026.6.16
#
# The CRD-sync gate in verify.yml re-runs this against the committed appVersion
# and fails on any diff, so a hand-edited or stale CRD is caught.
set -euo pipefail

image="${1:?usage: vendor-crds.sh <image> <version>}"
version="${2:?usage: vendor-crds.sh <image> <version>}"

# image -> (chart dir, source repo, CRD source directory within that repo).
case "$image" in
  ghcr.io/metio/jaas)
    chart="jaas"; repo="metio/jaas"; crd_dir="config/crd/bases" ;;
  ghcr.io/metio/stageset-controller)
    chart="stageset-controller"; repo="metio/stageset-controller"; crd_dir="config/crd" ;;
  *)
    echo "vendor-crds: unknown image '$image'" >&2; exit 1 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
templates="$root/charts/$chart/templates"
ref="$version"   # metio release tags are the bare calendar version (no 'v')

# Authenticate the GitHub API call when a token is available (bump.yml and the
# verify gate both export GH_TOKEN). Unauthenticated requests share a 60/hour
# per-IP budget that a busy runner can exhaust, surfacing as a spurious 404/403.
auth=()
[ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GH_TOKEN")

header() {
  # Go-template SPDX + rationale header prepended to every vendored CRD. The
  # raw controller-gen body (which begins with '---') follows verbatim.
  cat <<'EOF'
{{- /*
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD

CRDs live under templates/ (not crds/) so `helm upgrade` applies schema
changes automatically. The `helm.sh/resource-policy: keep` annotation keeps
`helm uninstall` from wiping the CRD (and every bound custom resource) — an
operator who genuinely wants them gone deletes the CRD by hand. Vendored from
the source repo by hack/vendor-crds.sh and pinned to the chart's appVersion;
the verify.yml CRD-sync gate fails on drift. Gated on .Values.crds.create
(default true) so the CRDs can be managed out-of-band — e.g. CI's chart-testing
installs the same chart once per ci values file, and a cluster-scoped
keep-policy CRD owned by the first release can't be re-adopted by the next.
*/ -}}
EOF
}

# List the CRD files in the source repo at this tag via the contents API.
files="$(curl -fsSL "${auth[@]}" \
  "https://api.github.com/repos/$repo/contents/$crd_dir?ref=$ref" \
  | jq -r '.[] | select(.name | endswith(".yaml")) | .name')"

[ -n "$files" ] || { echo "vendor-crds: no CRDs found in $repo/$crd_dir@$ref" >&2; exit 1; }

# Build the new set in a staging dir and swap it in only after EVERY fetch has
# succeeded. A per-file raw fetch can fail mid-loop (rate limit, transient 5xx);
# writing in place — or deleting the old set up front — would then leave the
# chart's CRDs half-written or half-deleted. Staging keeps the live tree intact
# until the whole vendor is known-good.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

for file in $files; do
  # plural is the trailing segment of <group>_<plural>.yaml
  plural="${file##*_}"; plural="${plural%.yaml}"
  raw="$(curl -fsSL "https://raw.githubusercontent.com/$repo/$ref/$crd_dir/$file")"
  # Inject the keep annotation directly after controller-gen's own annotation,
  # matching its two-space-under-annotations indentation.
  body="$(printf '%s\n' "$raw" \
    | sed '/controller-gen.kubebuilder.io\/version:/a\    helm.sh/resource-policy: keep')"
  # Fail loudly if the keep annotation wasn't injected — controller-gen changing
  # or dropping the anchor line would otherwise silently strip it, and a CRD
  # without resource-policy: keep is wiped (with every bound custom resource) on
  # `helm uninstall`.
  printf '%s\n' "$body" | grep -q 'helm.sh/resource-policy: keep' \
    || { echo "vendor-crds: failed to inject keep annotation into $file" >&2; exit 1; }
  {
    header
    printf '%s\n' '{{- if .Values.crds.create }}'
    printf '%s\n' "$body"
    printf '%s\n' '{{- end }}'
  } > "$stage/crd-$plural.yaml"
done

# Every fetch succeeded. Drop the old vendored set (so a CRD removed upstream
# disappears from the chart — without this an orphan crd-<old>.yaml lingers, the
# CRD-sync gate's git diff stays clean, and the chart ships a CRD the deployed
# binary no longer serves) and move the freshly staged set in. $templates is
# derived from the validated $chart and is never empty.
rm -f "$templates"/crd-*.yaml
for staged in "$stage"/crd-*.yaml; do
  base="$(basename "$staged")"
  mv "$staged" "$templates/$base"
  echo "vendored $repo/$crd_dir into charts/$chart/templates/$base"
done
