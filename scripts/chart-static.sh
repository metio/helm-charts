# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD

# The per-chart static gates: helm-schema, ct lint, helm-unittest, helm-docs
# render check, kube-score (default + every ci/ values variant), and
# kubeconform. Takes the
# chart name as $1. CRDs must already be vendored (the caller runs
# hack/vendor-chart-crds.sh first) so every gate renders against the CRDs the
# package ships.
chart="$1"
c="charts/${chart}/"

# Generate the values schema before anything renders. Helm validates values
# against values.schema.json whenever the file is present, and the file is
# gitignored because release-charts.sh generates it into the package — so
# without this step the gates validate against nothing, while a consumer
# installing the released chart validates against a schema no gate ever
# exercised. Regenerating here also means a leftover from an earlier run can
# never go stale: it is overwritten every time the gate runs.
echo "::group::helm-schema ${chart}"
helm-schema -c "$c" -k additionalProperties
echo "::endgroup::"

echo "::group::ct lint ${chart}"
ct lint --config ct.yaml --charts "charts/${chart}"
echo "::endgroup::"

# breto puts the helm-unittest plugin on HELM_PLUGINS, so `helm unittest` needs
# no plugin install.
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
# ci/additional-*-values.yaml adds containers the chart consumer supplies, which
# neither kube-score nor the registry sweep can hold to the chart's standards.
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
  case "$(basename "$vf")" in additional-*) continue ;; esac
  render "$(basename "$vf")" -f "$vf"
done

# Every image reference a chart composes must honour global.imageRegistry, so a
# cluster that admits one registry needs one value instead of one override per
# image — and so an image added later cannot quietly escape it. A per-path unit
# test cannot catch a NEW hardcoded image; this can. Runs only for charts that
# declare the value, so adding it to another chart opts that chart in.
if grep -qE '^[[:space:]]+imageRegistry:' "${c}values.yaml"; then
  echo "::group::image-registry sweep ${chart}"
  sentinel="sweep.invalid/mirror"
  sweep_render() {
    helm template release-x "$c" --set "global.imageRegistry=${sentinel}" "$@" |
      grep -oE '^[[:space:]]*(image|reference):[[:space:]]*"?[^"[:space:]]+' |
      sed -E 's/^[[:space:]]*(image|reference):[[:space:]]*"?//' |
      sort -u
  }
  escaped=""
  # tests/sweep-values.yaml turns on optional features that render an image but
  # that no ci/ values file enables, so the sweep sees those too.
  for vf in "" "${c}tests/sweep-values.yaml" "$c"ci/*-values.yaml; do
    [ -z "$vf" ] || [ -e "$vf" ] || continue
    case "$(basename "$vf")" in additional-*) continue ;; esac
    if [ -z "$vf" ]; then refs="$(sweep_render)"; else refs="$(sweep_render -f "$vf")"; fi
    for ref in $refs; do
      case "$ref" in
        "${sentinel}"/*) ;;
        *) escaped="${escaped}${ref} (${vf:-default values})"$'\n' ;;
      esac
    done
  done
  if [ -n "$escaped" ]; then
    echo "images not pulled from global.imageRegistry:"
    printf '%s' "$escaped"
    echo "compose each one through the chart's registry helper, or — for a value that"
    echo "is a whole image reference rather than a registry plus repository — leave it"
    echo "to the operator and say so in values.yaml."
    exit 1
  fi
  echo "every rendered image honours global.imageRegistry"
  echo "::endgroup::"
fi

echo "::group::kubeconform ${chart}"
helm template release-x "$c" |
  kubeconform -strict -summary -ignore-missing-schemas \
    -schema-location default \
    -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
echo "::endgroup::"
