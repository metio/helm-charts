<!--
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
-->

# Migrations

Breaking changes for the `jaas` chart, newest first. Each release links here;
review the entries above your installed version before `helm upgrade`.

## 2026.6.16

Inline S3 credentials are no longer accepted. The
`operator.storage.s3.accessKey`, `operator.storage.s3.secretKey`, and
`operator.storage.s3.sessionToken` values have been removed because they landed
on the pod command line (visible in `ps`, in the PodSpec, and in the stored Helm
release). A `helm upgrade` that still sets any of them fails values-schema
validation.

Supply S3 credentials one of two ways instead:

- Set `operator.storage.s3.credentialsSecret.name` to an existing Secret that
  carries `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optionally
  `AWS_SESSION_TOKEN`. The chart wires it into the pod via `envFrom`, and
  minio-go reads the keys from the environment.
- Or leave `credentialsSecret` empty and rely on the IAM/IRSA discovery chain
  (`AWS_*` env vars, EKS web-identity, EC2 metadata). Bind a cloud identity to
  the operator's ServiceAccount via `operator.serviceAccount.annotations`.

```sh
kubectl create secret generic jaas-s3-creds \
  --from-literal=AWS_ACCESS_KEY_ID=… \
  --from-literal=AWS_SECRET_ACCESS_KEY=…

helm upgrade --install jaas oci://ghcr.io/metio/helm-charts/jaas \
  --set operator.storage.s3.credentialsSecret.name=jaas-s3-creds
```

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
