# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD

# Package, push, sign, and release each changed chart. Driven by env so it runs
# identically under `nix develop --command`:
#   VERSION  the shared CalVer for this run
#   CHARTS   space-separated chart names to consider
#   REPO     github.com/<owner>/<repo> (for cosign + footer)
#   SHA      the commit the tags point at
#   GH_TOKEN / GITHUB_TOKEN  release + git-cliff API auth
# shellcheck disable=SC2153 # VERSION is an env input, not a typo of `version`
version="$VERSION"

# CHARTS is a space-separated list; word-splitting it is intentional.
# shellcheck disable=SC2086
for name in $CHARTS; do
  chart="charts/$name"
  [ -f "$chart/Chart.yaml" ] || {
    echo "no such chart: $name"
    continue
  }
  appVersion="$(grep -oP '^appVersion:\s*"?\K[^"]+' "$chart/Chart.yaml")"

  # The committed 0.0.0 placeholder means the controller image isn't released
  # yet, so the chart would deploy a non-existent image. Don't publish it until
  # Renovate bumps appVersion to a real release.
  if [ "$appVersion" = "0.0.0" ]; then
    echo "::notice::$name appVersion is the 0.0.0 placeholder — skipping release until its image is published."
    continue
  fi

  echo "::group::release $name $version (appVersion $appVersion)"
  # CRDs aren't committed — vendor this chart's CRDs from its controller release
  # so they're baked into the .tgz, matching the appVersion the chart deploys.
  hack/vendor-chart-crds.sh "$chart"
  helm dependency build "$chart"
  # Render the README from its template so it lands inside the .tgz (gitignored,
  # so it only exists for the lifetime of a package run).
  if [ -f "$chart/README.md.gotmpl" ]; then
    helm-docs --chart-search-root "$chart"
  fi
  # Generate values.schema.json into the chart dir so Helm's install-time value
  # validation ships inside the .tgz (also gitignored, generated per run).
  helm-schema -c "$chart" -k additionalProperties

  # This chart's last tag bounds both the Artifact Hub changelog and the GitHub
  # release notes below. Empty on a first release.
  prev="$(git tag --list "${name}-*" --sort=-creatordate | head -1)"

  # Inject an Artifact Hub `artifacthub.io/changes` annotation, computed by
  # git-cliff over this chart's commit range (the same range the notes use). The
  # edit is to the ephemeral CI checkout's Chart.yaml only, so it ships inside
  # the packaged .tgz. An empty range yields no annotation, which is correct.
  changes="$(CHART="$name" VERSION="$version" git-cliff --config-url "https://raw.githubusercontent.com/metio/git-cliff-config/16dc9654e9eb431d6169059509ce5552912a14ad/cliff-artifacthub.toml" --include-path "charts/${name}/**" --tag-pattern "^${name}-" ${prev:+"${prev}..HEAD"} 2>/dev/null | sed '/^[[:space:]]*$/d')"
  if [ -n "$changes" ]; then
    CHANGES="$changes" yq -i '.annotations."artifacthub.io/changes" = strenv(CHANGES)' "$chart/Chart.yaml"
  fi

  helm package "$chart" --version "$version" --app-version "$appVersion"
  pkg="${name}-${version}.tgz"

  # Push and capture the pushed digest for keyless signing.
  push_out="$(helm push "$pkg" oci://ghcr.io/metio/helm-charts 2>&1)"
  echo "$push_out"
  # A failed grep in a command substitution does NOT trip set -e (the assignment
  # masks the exit status), so validate explicitly — otherwise a changed
  # helm-push output format would leave digest empty and we'd sign a malformed
  # "...@" reference.
  digest="$(printf '%s\n' "$push_out" | grep -oP 'Digest:\s*\K\S+' || true)"
  [ -n "$digest" ] || {
    echo "::error::could not parse digest from helm push output for $name"
    exit 1
  }
  cosign sign --yes \
    --annotations "repo=${REPO}" \
    --annotations "chart=$name" \
    "ghcr.io/metio/helm-charts/${name}@${digest}"

  # Per-chart, path-scoped release notes since this chart's last tag. --tag
  # labels the (still uncreated) release so the shared cliff.toml header renders
  # this chart+version; --tag-pattern scopes release boundaries to this chart.
  cliff_args=(--config-url "https://raw.githubusercontent.com/metio/git-cliff-config/16dc9654e9eb431d6169059509ce5552912a14ad/cliff.toml" --include-path "charts/${name}/**"
    --tag "${name}-${version}" --tag-pattern "^${name}-")
  # A bare "HEAD" positional is rejected as a range; for the first release omit
  # the positional so git-cliff walks full history.
  [ -n "$prev" ] && cliff_args+=("${prev}..HEAD")
  CHART="$name" VERSION="$version" git-cliff "${cliff_args[@]}" >notes.md

  # Static footer: cosign verification + migration notes link.
  hack/release-footer.sh "$name" "$version" "${REPO}" >>notes.md

  tag="${name}-${version}"
  git tag "$tag" "${SHA}"
  git push origin "$tag"
  gh release create "$tag" --title "$tag" --notes-file notes.md
  rm -f "$pkg" notes.md
  echo "::endgroup::"
done
