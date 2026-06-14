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
| `charts/stageset-controller` | ordered, gated multi-stage Flux deployments | [metio/flux-stageset-controller](https://github.com/metio/flux-stageset-controller) |
| `charts/joi` | [JOI](https://github.com/metio/jsonnet-oci-images) images as Flux `OCIRepository` + JaaS `JsonnetLibrary` pairs | [metio/jsonnet-oci-images](https://github.com/metio/jsonnet-oci-images) |

Charts publish to **`oci://ghcr.io/metio/helm-charts/<name>`**. (GHCR package
names are free-form and decoupled from the repo name — `helm-charts/` is a
deliberate namespace choice, not a requirement.)

## Common commands

No host toolchain; everything runs in a containerized dev shell driven by
`dev/Containerfile`. A `.ilo.rc` at the repo root supplies the args, so the
short form works:

```shell
ilo bash -c 'ct lint --config ct.yaml'                                  # CI: chart-testing lint (changed charts)
ilo bash -c 'helm unittest charts/jaas charts/joi charts/stageset-controller'  # CI: helm-unittest
ilo bash -c 'helm-schema -c charts/jaas -k additionalProperties'        # regenerate a chart's values.schema.json
ilo bash -c 'helm template release-x charts/jaas | kube-score score -'  # static analysis of rendered chart
ilo bash -c 'helm template release-x charts/jaas | kubeconform -strict -ignore-missing-schemas -'  # schema validation
ilo bash -c 'helm template release-x charts/jaas'                       # render a chart with defaults
```

The dev shell bundles **helm v4** + `helm-unittest` (>= 1.1.0, installed with
`--verify=false` since helm v4 verifies plugin provenance and the plugin ships
none), `ct` (chart-testing), `kube-score`, `kubeconform`, `cosign`, `git-cliff`,
`helm-schema`, `yamllint`, and `yamale`. CI (`azure/setup-helm`) is pinned to the
same helm v4 so snapshots render identically in both.
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
then **vendored** into the chart by `hack/vendor-crds.sh`, which fetches the
source repo's CRDs at the released tag and injects the `helm.sh/resource-policy: keep`
annotation. CRDs live under each chart's `templates/crd-*.yaml` (not `crds/`) so
`helm upgrade` applies schema changes automatically. The **CRD-sync gate**
(verify.yml) re-runs the vendoring against each chart's committed `appVersion`
and fails on any diff — so a hand-edited or stale CRD is caught. The bump PR
(`bump.yml`) does the re-vendoring whenever Renovate moves `appVersion`.

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

## CI

`verify.yml` is the PR gate (changed-charts-only): `ct lint`, `helm-unittest`,
a **helm-schema drift gate** (regenerate `values.schema.json` from `values.yaml`
`@schema` annotations, fail on diff), **kube-score** (default + every `ci/`
variant, CRITICAL fails), **kubeconform** (rendered manifests incl. CRDs), the
**CRD-sync gate**, and **`ct install`** in kind across a **dynamically computed**
k8s matrix (a setup job queries kindest/node tags and takes the latest patch of
the newest N minors — Renovate can freshen existing entries but cannot grow a
list, so the matrix is generated at runtime). Separate jobs run yamllint,
actionlint, markdownlint, typos, and REUSE.

`operator-smoke.yml` is **angle 2 of the two-angle operator e2e** (see jaas's
CLAUDE.md): the **dev chart** (this PR's `charts/jaas`) deploys the **released
binary** (the chart's `appVersion`) and runs the *shared* operator scenarios —
the `hack/smoke/*.sh` scripts checked out from `metio/jaas` at the released tag.
It skips (green) until `appVersion` advances past `0.0.0`. The companion angle
(dev binary × released chart) lives in the jaas repo.

`release.yml` is **event-driven** on push to `main` touching `charts/**` (+
`workflow_dispatch`): per changed chart, `helm package` → `helm push
oci://ghcr.io/metio/helm-charts/<name>` → cosign keyless sign → a per-chart git
tag `<chart>-<version>` → a GitHub Release whose body is `git-cliff` notes
path-scoped to `charts/<name>/**` plus a static footer (`hack/release-footer.sh`:
cosign verify command + a link to the chart's `MIGRATIONS.md`).

`sync-joi.yml` regenerates `charts/joi/values.yaml` daily from JOI's published
`libraries.json` (`hack/gen-joi-values.sh`), so a new JOI library flows into the
chart with zero manual work.

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
