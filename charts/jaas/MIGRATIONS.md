<!--
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
-->

# Migrations

Breaking changes for the `jaas` chart, newest first. Each release links here;
review the entries above your installed version before `helm upgrade`.

## 2026.6.13

The chart's OCI location has moved. It is now published at
`oci://ghcr.io/metio/helm-charts/jaas`, not `oci://ghcr.io/metio/jaas`.

Charts already pulled from the old path keep working, but no new versions land
there. Re-point your source at the new path:

```sh
helm upgrade --install jaas oci://ghcr.io/metio/helm-charts/jaas
```

For a Flux `HelmRelease`, update the `OCIRepository` / `HelmRepository` URL to
`oci://ghcr.io/metio/helm-charts/jaas`. No values changes are required — only the
pull location.
