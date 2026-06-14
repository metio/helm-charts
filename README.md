<!--
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
-->

# helm-charts

The central repository for every [metio](https://github.com/metio) Helm chart.
Source repositories build and publish container **images**; this repository
builds and publishes the **charts** that deploy them. The two are versioned and
released independently.

See [`docs/design.md`](docs/design.md) for the full design — layout, versioning,
CRD provenance, CI, and release flow.

## Charts

| Chart | Deploys | OCI artifact |
|---|---|---|
| [`jaas`](charts/jaas) | [JaaS](https://github.com/metio/jaas) — Jsonnet-as-a-Service | `oci://ghcr.io/metio/helm-charts/jaas` |
| [`stageset-controller`](charts/stageset-controller) | [stageset-controller](https://github.com/metio/flux-stageset-controller) — ordered, gated Flux deployments | `oci://ghcr.io/metio/helm-charts/stageset-controller` |
| [`joi`](charts/joi) | [jsonnet-oci-images](https://github.com/metio/jsonnet-oci-images) as Flux `OCIRepository` + JaaS `JsonnetLibrary` pairs | `oci://ghcr.io/metio/helm-charts/joi` |

Install a chart straight from its OCI location:

```sh
helm upgrade --install jaas oci://ghcr.io/metio/helm-charts/jaas
```

Each release is cosign-signed; the GitHub Release for a chart version carries the
exact `cosign verify` command and a link to that chart's `MIGRATIONS.md`.

## Versioning

A chart's `version` is calendar-plus-time (`%Y.%-m.%-d+%H%M%S`, e.g.
`2026.6.16+142305`) stamped at release; its `appVersion` is the image it deploys,
committed and bumped by Renovate. A chart is re-released only when its templates
change or its `appVersion` advances.

## Development

Tooling runs in a containerized [`ilo`](dev/Containerfile) dev shell — no host
toolchain required:

```sh
ilo bash -c 'ct lint --config ct.yaml'                       # lint changed charts
ilo bash -c 'helm unittest charts/jaas'                       # template assertions + snapshots
ilo bash -c 'helm-schema -c charts/jaas -k additionalProperties'  # regenerate values.schema.json
ilo bash -c 'helm template release-x charts/jaas | kube-score score -'  # static analysis
```

## License

[0BSD](LICENSES/0BSD.txt) — the repository is [REUSE](https://reuse.software)
compliant; see [`REUSE.toml`](REUSE.toml) for per-path metadata.
