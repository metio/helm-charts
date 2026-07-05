# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD

# The per-chart static gates: ct lint, helm-unittest, helm-docs render check,
# kube-score (default + every ci/ values variant), and kubeconform. Takes the
# chart name as $1. CRDs must already be vendored (the caller runs
# hack/vendor-chart-crds.sh first) so every gate renders against the CRDs the
# package ships.
chart="$1"
c="charts/${chart}/"

echo "::group::ct lint ${chart}"
ct lint --config ct.yaml --charts "charts/${chart}"
echo "::endgroup::"

# helm is wrapped with the unittest plugin in the flake, so there is no plugin
# to install — `helm unittest` just works.
if [ -d "${c}tests" ]; then
  echo "::group::helm-unittest ${chart}"
  helm unittest "$c"
  echo "::endgroup::"
fi

# The README is rendered into the package at release time, not committed; this
# only proves the template still renders (a broken README.md.gotmpl fails here).
if [ -f "${c}README.md.gotmpl" ]; then
  echo "::group::helm-docs render ${chart}"
  helm-docs --chart-search-root "$c"
  echo "::endgroup::"
fi

# kube-score on the default render and each ci/ values variant; CRITICAL fails.
render() {
  label="$1"
  shift
  echo "::group::kube-score ${chart} ${label:-default}"
  helm template release-x "$c" "$@" | kube-score score - --exit-one-on-warning=false
  echo "::endgroup::"
}
render default
for vf in "$c"ci/*-values.yaml; do
  [ -e "$vf" ] || continue
  render "$(basename "$vf")" -f "$vf"
done

echo "::group::kubeconform ${chart}"
helm template release-x "$c" |
  kubeconform -strict -summary -ignore-missing-schemas \
    -schema-location default \
    -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
echo "::endgroup::"
