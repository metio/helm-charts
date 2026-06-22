{{- /*
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
*/ -}}

{{- /* One cleanup-Job container running `kubectl delete jsonnetsnippets`. Expects
       a dict: root (the chart context $), name (container name), scopeArg (either
       --all-namespaces or --namespace=<ns>), cacheDir (a unique discovery-cache
       path so concurrent per-namespace containers don't race on one dir).
       registry.k8s.io/kubectl is distroless (no /bin/sh), so each container can
       run only one kubectl invocation — hence one container per watched namespace
       rather than a shell loop. */ -}}
{{- define "jaas.cleanupContainer" -}}
- name: {{ .name }}
  image: "{{ .root.Values.operator.cleanupOnDelete.image.registry }}/{{ .root.Values.operator.cleanupOnDelete.image.repository }}:{{ .root.Values.operator.cleanupOnDelete.image.tag }}"
  imagePullPolicy: {{ .root.Values.operator.cleanupOnDelete.image.pullPolicy }}
  args:
    - delete
    - jsonnetsnippets.jaas.metio.wtf
    - --all
    - {{ .scopeArg }}
    - --wait=true
    - --timeout={{ .root.Values.operator.cleanupOnDelete.kubectlTimeout }}
    - --ignore-not-found
    - --cache-dir={{ .cacheDir }}
  volumeMounts:
    - name: cache
      mountPath: /tmp
  securityContext:
    runAsNonRoot: true
    runAsGroup: 65532
    runAsUser: 65532
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
  resources:
    requests:
      cpu: {{ .root.Values.operator.cleanupOnDelete.resources.cpu }}
      memory: {{ .root.Values.operator.cleanupOnDelete.resources.memory }}
      ephemeral-storage: {{ .root.Values.operator.cleanupOnDelete.resources.ephemeralStorage }}
    limits:
      cpu: {{ .root.Values.operator.cleanupOnDelete.resources.cpu }}
      memory: {{ .root.Values.operator.cleanupOnDelete.resources.memory }}
      ephemeral-storage: {{ .root.Values.operator.cleanupOnDelete.resources.ephemeralStorage }}
{{- end -}}
