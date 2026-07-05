# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD

# Regenerate charts/joi/values.yaml + its generated tests from JOI's published
# libraries.json, guarding against an upstream discovery failure silently
# dropping libraries. Env: ALLOW_SHRINK ("true" permits dropping libraries).
# The caller commits any change in a separate step.
if ! curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 https://raw.githubusercontent.com/metio/jsonnet-oci-images/main/libraries.json -o /tmp/libraries.json; then
  echo "JOI manifest not published yet — nothing to sync"
  exit 0
fi

# Library names currently shipped by the chart (2-space keys under `libraries:`),
# captured before the file is overwritten.
libnames() { awk '/^libraries:/{f=1;next} f && /^  [A-Za-z0-9]/{sub(/:[[:space:]]*$/,"");gsub(/^[[:space:]]+/,"");print}' "$1" | sort; }
libnames charts/joi/values.yaml >/tmp/old-libs.txt
bash hack/gen-joi-values.sh /tmp/libraries.json >charts/joi/values.yaml
# Per-library helm-unittest coverage from the same source — one automated path
# (libraries.json -> values.yaml -> test) so the cases can't drift.
bash hack/gen-joi-tests.sh /tmp/libraries.json >charts/joi/tests/libraries-generated_test.yaml

# Shrink-guard: a transient upstream discovery failure can leave the JOI
# manifest missing healthy libraries; mirroring it would silently drop them.
# Abort if any currently-shipped library disappears, unless allow_shrink
# acknowledges a real upstream removal.
libnames charts/joi/values.yaml >/tmp/new-libs.txt
dropped="$(comm -23 /tmp/old-libs.txt /tmp/new-libs.txt)"
if [ -n "$dropped" ] && [ "${ALLOW_SHRINK:-}" != "true" ]; then
  echo "::error::sync would drop libraries the chart currently ships:"
  while IFS= read -r lib; do
    echo "::error::  - $lib"
  done <<<"$dropped"
  echo "::error::if these were genuinely removed from the JOI manifest, re-run with allow_shrink=true; otherwise this is a transient upstream discovery failure — fix JOI and re-run."
  git checkout -- charts/joi/values.yaml charts/joi/tests/libraries-generated_test.yaml
  exit 1
fi

helm-schema -c charts/joi -k additionalProperties >/dev/null
