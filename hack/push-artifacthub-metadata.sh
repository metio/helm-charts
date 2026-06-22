#!/usr/bin/env bash
# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD
#
# Pushes each chart's Artifact Hub repository metadata to the OCI registry under
# the special `:artifacthub.io` tag, which is how Artifact Hub verifies ownership
# of an OCI-based Helm repository (the metadata is NOT read from git for OCI).
#
# The repositoryID is static, so this is a ONE-TIME push per chart — re-run only
# if a registry repo is recreated. Requires `oras` and a ghcr.io login
# (`oras login ghcr.io -u <user>` or an existing `helm registry login`).
#
#   hack/push-artifacthub-metadata.sh            # all charts that have metadata
#   hack/push-artifacthub-metadata.sh jaas       # a single chart
set -euo pipefail

registry="ghcr.io/metio/helm-charts"
charts=("$@")
if [ ${#charts[@]} -eq 0 ]; then
  # Every chart that ships an artifacthub-repo.yml. Glob directly rather than
  # parsing ls (SC2012) — the [ -e ] guard handles the no-match literal-glob.
  for meta in charts/*/artifacthub-repo.yml; do
    [ -e "$meta" ] || continue
    charts+=("$(basename "$(dirname "$meta")")")
  done
fi

for chart in "${charts[@]}"; do
  meta="charts/${chart}/artifacthub-repo.yml"
  [ -f "$meta" ] || { echo "::warning::no metadata for $chart ($meta) — skipping"; continue; }
  echo "==> pushing ${meta} -> ${registry}/${chart}:artifacthub.io"
  # cd into the chart dir so the layer is named `artifacthub-repo.yml`, not the
  # full path.
  ( cd "charts/${chart}" && oras push "${registry}/${chart}:artifacthub.io" \
      --config /dev/null:application/vnd.cncf.artifacthub.config.v1+yaml \
      "artifacthub-repo.yml:application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml" )
done
