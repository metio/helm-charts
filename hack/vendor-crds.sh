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
the verify.yml CRD-sync gate fails on drift.
*/ -}}
EOF
}

# List the CRD files in the source repo at this tag via the contents API.
files="$(curl -fsSL \
  "https://api.github.com/repos/$repo/contents/$crd_dir?ref=$ref" \
  | jq -r '.[] | select(.name | endswith(".yaml")) | .name')"

[ -n "$files" ] || { echo "vendor-crds: no CRDs found in $repo/$crd_dir@$ref" >&2; exit 1; }

for file in $files; do
  # plural is the trailing segment of <group>_<plural>.yaml
  plural="${file##*_}"; plural="${plural%.yaml}"
  out="$templates/crd-$plural.yaml"
  raw="$(curl -fsSL "https://raw.githubusercontent.com/$repo/$ref/$crd_dir/$file")"
  # Inject the keep annotation directly after controller-gen's own annotation,
  # matching its two-space-under-annotations indentation.
  body="$(printf '%s\n' "$raw" \
    | sed '/controller-gen.kubebuilder.io\/version:/a\    helm.sh/resource-policy: keep')"
  { header; printf '%s\n' "$body"; } > "$out"
  echo "vendored $repo/$crd_dir/$file -> charts/$chart/templates/crd-$plural.yaml"
done
