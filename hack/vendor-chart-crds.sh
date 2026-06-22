#!/usr/bin/env bash
# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD
#
# Vendor one chart's CRDs from its controller release into templates/, reading
# the image and version straight from the chart's Chart.yaml. CRDs are a build
# artifact (gitignored, see .gitignore): packaging and every CI job that renders
# or installs a chart regenerates them on the fly, so the chart's CRDs always
# match the appVersion it deploys without a committed copy that can drift.
#
#   hack/vendor-chart-crds.sh charts/jaas
#
# Export GH_TOKEN to authenticate the GitHub API lookups (unauthenticated
# requests share a 60/hour per-IP budget a busy runner can exhaust).
#
# No-ops cleanly when the chart has no `# renovate: image=` marker (no CRDs to
# vendor) or its appVersion is still the 0.0.0 bootstrap placeholder (the source
# repo has cut no release to vendor from yet).
set -euo pipefail

chart_dir="${1:?usage: vendor-chart-crds.sh <chart-dir>}"
cf="$chart_dir/Chart.yaml"
[ -f "$cf" ] || { echo "vendor-chart-crds: no Chart.yaml at $cf" >&2; exit 1; }

image="$(grep -oP '#\s*renovate:\s*image=\K\S+' "$cf" || true)"
if [ -z "$image" ]; then
  echo "vendor-chart-crds: $chart_dir has no renovate image marker — no CRDs to vendor."
  exit 0
fi

appVersion="$(grep -oP '^appVersion:\s*"?\K[^"]+' "$cf")"
if [ "$appVersion" = "0.0.0" ]; then
  echo "vendor-chart-crds: $chart_dir appVersion is the 0.0.0 placeholder — no released $image to vendor from yet; skipping."
  exit 0
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
exec "$root/hack/vendor-crds.sh" "$image" "$appVersion"
