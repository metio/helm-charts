#!/usr/bin/env bash
# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD
#
# Emit the static footer appended to every chart's GitHub Release body:
# cosign verification instructions + a link to the chart's migration notes.
#
#   hack/release-footer.sh <chart-name> <version> <repo> >> notes.md
#
# <version> is the chart's CalVer (e.g. 2026.6.20143022); it doubles as the OCI
# tag verbatim, since the version carries no characters Helm rewrites for OCI.
set -euo pipefail

name="${1:?chart name}"
oci_tag="${2:?version}"
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
