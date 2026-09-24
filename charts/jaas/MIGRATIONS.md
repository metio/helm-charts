<!--
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
-->

# Migrations

Breaking changes for the `jaas` chart, newest first. Each release links here;
review the entries above your installed version before `helm upgrade`.

## 2026.9.24

Egress to the kube-apiserver is its own value now, and the chart renders it in
the selected engine's own dialect. Two installs need an edit before
`helm upgrade`, both only when `operator.enabled` and
`networkPolicy.egress.enabled` are set.

**`networkPolicy.engine: kubernetes`** now requires the apiserver addresses in
`networkPolicy.egress.kubernetesAPI.ipBlocks`; a render with that list empty
fails instead of producing a policy that denies the operator its apiserver.
Move the CIDR out of `networkPolicy.egress.to`, where it used to be hand-written,
and set the endpoint port alongside it:

```yaml
networkPolicy:
  egress:
    kubernetesAPI:
      ipBlocks:
        - 10.24.64.1/32
      port: 6443
```

`kubectl --namespace default get endpoints kubernetes` reports both. An entry
left behind in `networkPolicy.egress.to` renders a second, redundant rule rather
than an error. Installs that admit the apiserver through some other policy set
`networkPolicy.egress.kubernetesAPI.enabled: false` and keep their own list.

**`networkPolicy.engine: calico`** scopes its DNS rule to
`networkPolicy.egress.dnsNamespace` (default `kube-system`), matching the three
other engines; it previously allowed port 53 to any destination. A cluster whose
resolver lives elsewhere sets `dnsNamespace` to that namespace, and one that
resolves through an off-cluster server adds a rule for it to
`networkPolicy.calico.egress`.

The `calico` and `cilium` engines need no CIDR at all: they select the apiserver
by Kubernetes Service and by entity respectively.

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
