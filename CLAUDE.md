<!--
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
-->

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

The central monorepo for **every metio Helm chart**. The guiding split: source
repos build and publish container images; this repo builds and publishes the
**charts** that deploy them. A chart here references an image by version — it
never builds one. The two are versioned and released independently.

Charts:

| Chart | Deploys | Source repo |
|---|---|---|
| `charts/jaas` | JaaS (Jsonnet-as-a-Service) operator + HTTP evaluator | [metio/jaas](https://github.com/metio/jaas) |
| `charts/stageset-controller` | ordered, gated multi-stage Flux deployments | [metio/stageset-controller](https://github.com/metio/stageset-controller) |
| `charts/joi` | [JOI](https://github.com/metio/jsonnet-oci-images) images as Flux `OCIRepository` + JaaS `JsonnetLibrary` pairs | [metio/jsonnet-oci-images](https://github.com/metio/jsonnet-oci-images) |

Charts publish to **`oci://ghcr.io/metio/helm-charts/<name>`**. (GHCR package
names are free-form and decoupled from the repo name — `helm-charts/` is a
deliberate namespace choice, not a requirement.)

## Common commands

The toolchain is a **nix flake** (`flake.nix` + `flake.lock`, Renovate-maintained):
CI runs every gate through the flake's devShell, so a local run and CI resolve
the same versions. Multi-step gates are `writeShellApplication` commands in
`scripts/` — on `$PATH` inside `nix develop`, callable one-shot:

```shell
nix develop --command chart-static jaas   # ct lint + helm-unittest + helm-docs + kube-score + kubeconform for a chart
nix develop --command reuse lint          # the single-tool gates call the tool directly:
nix develop --command yamllint .
nix develop --command actionlint
nix develop --command markdownlint-cli2 '**/*.md'
nix develop --command typos
nix develop --command helm-schema -c charts/jaas -k additionalProperties  # regenerate a chart's values.schema.json
nix develop --command helm template release-x charts/jaas                 # render a chart with defaults
```

Or drop into the shell (`nix develop` prints the command menu) and run tools
bare. The devShell provides **helm v4 wrapped with `helm-unittest`** (via
`wrapHelm`, so `helm unittest` works with no plugin install), `ct`
(chart-testing), `kube-score`, `kubeconform`, `helm-docs`, `cosign`,
`git-cliff`, `yq`, `yamllint`, `yamale`, and the shared lint gate. dadav's
`helm-schema` is not in nixpkgs, so the flake builds it from source
(`packages.helm-schema`). The `ct install` / kind-cluster smoke gates keep
`chart-testing-action` + `kind-action` — building real clusters is a runner
operation, not a devShell one. On this host `nix` is nix-portable (see the
root `CLAUDE.md`'s nix section); a system install is not possible.
golangci-lint is irrelevant here (there is no Go), but the project-wide ban
still applies if any tooling ever tempts it.

## Versioning (two decoupled fields)

- **Chart `version`** — `%Y.%-m.%-d+%H%M%S` (e.g. `2026.6.16+142305`), stamped
  at release time, **per chart, only when that chart changed**. The committed
  `Chart.yaml` keeps a `0.0.0` placeholder; the release pipeline rewrites it.
  The `+%H%M%S` is **SemVer build metadata** — Helm requires valid SemVer 2.0.0
  (exactly three numeric segments, no leading zeros), so a fourth segment or a
  time-in-`PATCH` is invalid, but build metadata is not, and Helm renders it
  into the OCI tag by replacing `+` with `_` (`2026.6.16_142305`).
- **Chart `appVersion`** — the controller **image** version the chart deploys
  (also calendar). **Committed** in `Chart.yaml` (meaningful state) and bumped
  by Renovate when the source repo publishes a new image. `image.tag` defaults
  to `.Chart.AppVersion`, so bumping `appVersion` moves the deployed image.

They are decoupled because the image no longer releases from the same repo on
the same run. A chart re-releases when its templates change **or** its
`appVersion` advances; a quiet week releases nothing.

## CRD provenance

CRDs are generated in the **source** repos (`controller-gen` → `config/crd`),
then **vendored** into the chart by `hack/vendor-crds.sh <image> <appVersion>`,
which fetches the source repo's CRDs at the released tag (resolved from the
fully-qualified `# renovate: image=…` marker in `Chart.yaml`) and injects the
`helm.sh/resource-policy: keep` annotation. CRDs live under each chart's
`templates/crd-*.yaml` (not `crds/`) so `helm upgrade` applies schema changes
automatically. The **CRD-sync gate** (`verify.yml`, per-chart) re-runs the
vendoring against each chart's committed `appVersion` and fails on any diff — so
a hand-edited or stale CRD is caught. A chart on the `0.0.0` placeholder is
skipped (no released tag to vendor from yet).

The re-vendoring on a Renovate `appVersion` bump is done by **`sync-joi.yml`'s
sibling, `bump.yml`** (workflow name "Sync CRDs on appVersion bump"): it fires on
pushes to `renovate/**` branches touching a `charts/*/Chart.yaml`, re-vendors
every non-placeholder chart's CRDs, and commits the result back onto the Renovate
branch — so the bump PR already carries matching CRDs and passes the sync gate.
This is a **separate workflow because hosted Renovate cannot run the vendor
script itself** (no `postUpgradeTasks`).

## The `common` library chart (planned, not yet extracted)

jaas and stageset-controller are near-identical Flux controllers (Deployment +
PSS securityContext, RBAC with the `--watch-namespaces` pivot, webhook in
cert-manager **and** self-signed modes, metrics Service/ServiceMonitor/
PrometheusRule, opt-in NetworkPolicy, namespace PSS labels, HPA/PDB gated on
`replicas.max > replicas.min`). The plan is to factor that into a `common`
**library chart** (`type: library`, local `file://../common` dependency, never
published) and have each app chart depend on it. **Phased:** both charts moved
in as-is first; the extraction comes later, guarded by helm-unittest snapshots
(rendered output must not change). `charts/stageset-controller` already uses a
`_helpers.tpl` to pre-figure that shape.

## CI & test layers

### Per-chart isolation (the guiding principle)

`verify.yml` is the PR gate and operates **only on charts changed in the PR** — a
`changed` job runs `ct list-changed` and emits the chart set as a JSON array. The
**static gates** (`ct lint`, helm-unittest, helm-schema drift, kube-score,
kubeconform) and the **CRD-sync gate** then run as a **per-chart matrix** — one
independent job per changed chart, `fail-fast: false`. The point is isolation: a
stale `values.schema.json` or a drifted CRD in one chart can never block an
unrelated chart's PR.

The **one exception** is `ct install`: it is a single job matrixed over
*Kubernetes versions* (not charts), running `ct install` once per k8s version for
all installable changed charts at once. It also gates on `installable_any` — a
chart still on the `0.0.0` `appVersion` placeholder has no released image to pull,
so it's added to an `--excluded-charts` list (and the whole install job skips if
nothing installable is left).

Every `verify.yml` leg (incl. the chart and k8s matrices) rolls up into a single
stably-named **`Verify — all checks passed`** aggregate job. That aggregate is the
*only* check to mark required in branch protection — matrix leg names change with
the discovered chart set / k8s versions, so they can't be enumerated as required
checks individually. The aggregate passes only if every dependency succeeded or
was intentionally skipped.

### Test layers

A chart's verification has these distinct layers, in roughly increasing cost:

- **`ct lint`** — `Chart.yaml` validity, maintainer login, version-bump-on-change.
- **helm-unittest** — per-template assertions + rendered snapshots. Tests live in
  `charts/<name>/tests/*_test.yaml` with snapshots under
  `charts/<name>/tests/__snapshot__/`; the job runs `helm unittest charts/<name>/`
  only when that `tests/` dir exists. One test file per template family (Deployment,
  RBAC, webhook, services, HPA/PDB, NetworkPolicy, metrics, …) asserting the
  rendered shape; the joi chart's test pins `spec.url` of the `OCIRepository`
  **exactly** (a regex would hide a `docker:pinDigests`-style breakage — see the
  Renovate note below). The plugin is installed with `--verify=false` (helm v4
  verifies plugin provenance and helm-unittest ships none).
- **helm-schema drift gate** — regenerate `values.schema.json` from `values.yaml`
  `# @schema` annotations and fail on any diff, so the committed schema can't rot.
- **kube-score** — render the chart with **defaults plus every
  `charts/<name>/ci/*-values.yaml` variant** and fail on a CRITICAL. The same
  `ci/` value files double as the `ct install` install variants, so one set of
  representative value combinations (operator / webhook-self-signed / persistence /
  networkpolicy / watch-namespaces / HA / rollback-store …) feeds both gates.
- **kubeconform** — validate the rendered manifests (including the chart's CRDs)
  against Kubernetes + the CRD catalog.
- **CRD-sync gate** — vendored CRDs match the source repo's tag for `appVersion`
  (see *CRD provenance*).
- **`ct install`** — spin up kind, install cluster prereqs (cert-manager, the Flux
  source-controller CRDs for `ExternalArtifact`, the Prometheus-Operator CRDs for
  ServiceMonitor/PrometheusRule, a self-signed `ClusterIssuer`, and the
  `team-a`/`team-b` namespaces the watch-namespaces variant binds into), apply
  every chart's CRDs once (the `ci/` values install with `crds.create=false`
  because a kept cluster-scoped CRD owned by one release can't be re-adopted by the
  next), then `ct install` the changed charts and wait for Ready. This is where a
  bad `appVersion` image bump is caught.

The **dynamically computed k8s matrix** (a `k8s-matrix` job) queries the
`kindest/node` Docker tags and takes the latest patch of the newest N minors:
Renovate can *freshen* existing entries but cannot *grow* a list, so a new minor
would never be auto-added — generating the matrix at runtime fixes that, at the
cost of an unreviewed matrix change. `kindest/node` is the datasource (not
`kubernetes/kubernetes`) because kind is what constrains which versions are
installable.

The text linters live in **separate, always-running jobs** (not per-chart):
`yamllint`, `actionlint`, `markdownlint`, `typos`, and **REUSE** (the latter in
its own `reuse.yml`). They mirror the configs the source repos use so charts lint
the same way the code does.

`actionlint` is a **failing gate** — the `github-actions` job runs
`nix develop --command actionlint`, so findings block the merge across the whole
tree, not just changed lines. actionlint shells out to `shellcheck` to lint
`run:` blocks, so the flake devShell includes `shellcheck`; without it
`actionlint` silently skips shell linting and the local gate diverges from CI.
shellcheck findings are fixed at
the source (quote expansions, `find` over `ls`, grouped redirects), not suppressed.
Kept identical across jaas / stageset-controller / helm-charts.

### Operator e2e smoke (angle 2 of the two-angle strategy)

There is **one smoke workflow per controller chart**: `operator-smoke.yml` (jaas)
and `stageset-smoke.yml` (stageset-controller). Both are **angle 2 of the
two-angle e2e** (see the controller repos' CLAUDE.md): the **dev chart** (this
PR's `charts/<name>`) deploys the **released binary** — the chart's own
`appVersion`, kept current by Renovate — and runs the *shared* `hack/smoke/*.sh`
scenarios **checked out from the controller repo at the released tag**, so the
assertions match that binary's contract. The companion angle (dev binary ×
released chart) lives in each controller repo. Only the deploy differs between the
angles; the scenario scripts are shared. Because the dev chart vendors its CRDs at
its own `appVersion`, those already match the deployed binary — no CRD overlay is
needed here (unlike the controller-repo angle).

Both smoke workflows run on **every PR with no `paths:` filter** (so the
`all-green` aggregate always reports a status and can be required) but gate the
expensive kind jobs internally on a `discover.relevant` git-diff output — the kind
jobs run only when the PR touched that chart or the smoke workflow itself. They
also **skip green until `appVersion` advances past `0.0.0`** (no released image to
test). Both `discover` test versions at runtime: the newest installable kindest
minor, the newest kind binary (pinned to the node image so a lagging bundled kind
doesn't break a brand-new minor), and — for jaas — the newest Flux at/above the
`ExternalArtifact` floor plus the k8s subset where `ImageVolume` works on kind
(for the dedicated image-volume-library coverage). A new k8s/Flux release is
tested automatically; if kind can't run it yet, the failure is the wanted signal.

### Release

`release.yml` is **event-driven** on push to `main` touching `charts/**` (+
`workflow_dispatch` to force one or all charts). For each chart changed since its
last release (the `common` library chart is always excluded — it's a `file://`
dependency, never published):

1. `helm dependency build` (vendors any `file://` dep).
2. `helm package --version "$(date +'%Y.%-m.%-d+%H%M%S')" --app-version <appVersion>`.
3. `helm push oci://ghcr.io/metio/helm-charts` (the chart name becomes the package).
4. **cosign keyless sign** the pushed digest (Fulcio/Rekor, OIDC — no key).
5. per-chart git tag `<chart>-<version>` + a GitHub Release whose body is
   **`git-cliff`** notes scoped to `charts/<name>/**` over the
   `<chart>-<prev>..HEAD` range (`--tag-pattern "^<chart>-"` keeps another chart's
   tag in the range from splitting the notes), plus a static footer
   (`hack/release-footer.sh`: the `cosign verify` command + a link to the chart's
   `MIGRATIONS.md`).

A chart on the `0.0.0` placeholder is skipped (its image isn't published yet).

`sync-joi.yml` regenerates `charts/joi/values.yaml` daily (and on a JOI
`repository_dispatch`) from JOI's published `libraries.json`
(`hack/gen-joi-values.sh`), regenerates the schema, and commits any change — so a
new JOI library flows into the chart with zero manual work. A **shrink-guard**
aborts the sync if a currently-shipped library would disappear (a transient JOI
discovery failure), unless `allow_shrink` acknowledges a real upstream removal.

## Conventions & traps

- **No committed `CHANGELOG.md`** and **no `artifacthub.io/changes` annotations**
  — a CI-written changelog would re-trigger the event-driven release loop, and
  the charts are not on Artifact Hub. GitHub Releases filtered by the `<chart>-*`
  tag prefix **are** the changelog. `MIGRATIONS.md` (per chart, one level-1
  heading per version) is hand-authored in the same PR as the breaking change.
- **`Chart.yaml` `maintainers[].name` must be the GitHub login `sebhoss`**, not
  a display name — `ct lint` validates it against the GitHub API.
- **`renovate.json` extends the org-wide preset** `github>metio/renovate-config`
  (shared policy: `config:recommended`, assignees, `dependencies` label,
  automerge incl. majors). Only the
  **repo-specific** managers live locally: the controller-image packageRule and
  the appVersion customManager. Don't re-add generic presets here — put org-wide
  policy in the org repo.
- **The `helm-values` manager is disabled** (`"helm-values": {"enabled": false}`).
  Chart-values images are managed *by design* — controllers via the appVersion
  customManager, joi via mutable tags refreshed by `sync-joi.yml`. The org
  preset's `docker:pinDigests` would otherwise append `@sha256:…` digests to
  values-file image refs, which **breaks the joi `OCIRepository`**: the template
  builds `spec.url: oci://{{ .image }}` and the digest belongs in `spec.ref`, not
  the url. The `joi_test.yaml` exact-match on `spec.url` is the guard — keep it
  exact (a regex would hide that breakage).
- **`# renovate: image=…` annotations are fully qualified** (`ghcr.io/metio/jaas`,
  `ghcr.io/metio/stageset-controller`). The same image string keys both the
  Renovate `matchPackageNames` rule and the `hack/vendor-crds.sh` case — they
  move together. A short-form value (missing `ghcr.io/`) silently breaks the
  bump: the Docker datasource resolves it to Docker Hub and it won't match the
  packageRule. The packageRule sets `versioning: semver` so the calendar tags
  order correctly.
- **The `joi` chart is deliberately NOT Renovate-managed.** Its per-library
  `tag` defaults to `latest` (the library version is chosen in the *import path*,
  not the tag), so there are no `# renovate:` markers in `charts/joi/values.yaml`.
  Image freshness comes from JOI rebuilding `:latest` on upstream change + the
  `OCIRepository` re-pull `interval` + `sync-joi.yml` regenerating the library
  set. JOI also publishes immutable dated tags (`:<YYYY.M.D>`) a user can set on
  a library's `tag` to pin a snapshot — that's a manual user choice, still not
  Renovate's job. Don't add a Renovate manager for it.
- **The jaas chart enforces mode mutual-exclusivity at template time.** Flux
  operator mode (`operator.enabled=true`) and static OCI mounts (`snippets` /
  `additionalLibraries`) cannot coexist in one release — `templates/validate-modes.yaml`
  `fail`s if both are set, and `validate-modes_test.yaml` pins both the accepted
  and rejected combinations. The webhook templates similarly `fail` on an invalid
  `certMode` or a cert-manager mode missing its issuer. These render-time guards
  turn a misconfiguration into a clear `helm template` error instead of a broken
  deployment; keep them and their unittest assertions in lockstep.
- **`spec.selector.matchLabels` is immutable.** Strip volatile identity labels
  (`managed-by`, `version`, `helm.sh/chart`) from it, or a `helm upgrade` that
  changes one fails with "field is immutable". **Conversely, keep** version-bound
  labels in `topologySpreadConstraints`/`podAntiAffinity` `labelSelector`s —
  those are evaluated per scheduling decision and version-scoping them keeps a
  rolling release well-spread.
- The `release.yml` footer lives in `hack/release-footer.sh` (not inline) because
  a markdown `---` inside a YAML block scalar breaks the scalar.
- `dadav/helm-schema` release tags carry **no `v` prefix** (e.g. `0.23.4`); the
  asset is `helm-schema_<v>_Linux_x86_64.tar.gz`.

## Licensing / REUSE

0BSD, REUSE-compliant. Every file carries an SPDX header (markdown via `<!-- -->`,
YAML/shell via `#`) or a `REUSE.toml` glob. The `reuse` workflow enforces it.
