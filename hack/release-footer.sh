#!/usr/bin/env bash
# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD
#
# Emit the static footer appended to every chart's GitHub Release body:
# cosign verification instructions + a link to the chart's migration notes.
#
#   hack/release-footer.sh <chart-name> <oci-tag> <repo> >> notes.md
#
# <oci-tag> is the OCI tag form of the chart version (Helm renders SemVer
# build-metadata '+' as '_'), e.g. 2026.6.16_142305.
set -euo pipefail

name="${1:?chart name}"
oci_tag="${2:?oci tag}"
repo="${3:?owner/repo}"

cat <<EOF

---

### Verify this chart

\`\`\`sh
cosign verify ghcr.io/metio/helm-charts/${name}:${oci_tag} \\
  --certificate-identity-regexp '^https://github.com/${repo}/\\.github/workflows/release\\.yml@refs/' \\
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
\`\`\`

### Upgrading

Review [\`charts/${name}/MIGRATIONS.md\`](https://github.com/${repo}/blob/main/charts/${name}/MIGRATIONS.md) for any required changes before \`helm upgrade\`.
EOF
