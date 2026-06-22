{{- /*
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
*/ -}}

{{- /* Fully-qualified resource name. */ -}}
{{- define "stageset.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- /* The image reference, registry/repository:tag (tag defaults to appVersion). */ -}}
{{- define "stageset.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.repository $tag -}}
{{- end -}}

{{- /* Common metadata labels (includes version-bound labels). */ -}}
{{- define "stageset.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/component: controller
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- /* Immutable selector labels. Deliberately omits version-bound and
       managed-by labels (a Deployment/Service/PDB selector is immutable, so a
       helm upgrade that changes them would fail with "field is immutable"). */ -}}
{{- define "stageset.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/component: controller
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
{{- end -}}

{{- /* The namespace the webhook Service lives in (and the controller's own ns). */ -}}
{{- define "stageset.namespace" -}}
{{- .Release.Namespace -}}
{{- end -}}

{{- /* Whether the HPA should render: autoscaling is only meaningful when the
       ceiling is above the floor. */ -}}
{{- define "stageset.scaling" -}}
{{- if gt (.Values.replicas.max | int) (.Values.replicas.min | int) -}}true{{- end -}}
{{- end -}}

{{- /* Whether more than one replica can run — either the HPA can scale above
       one (max > min) OR a fixed count is pinned above one (min > 1). The
       PodDisruptionBudget gates on this, not stageset.scaling, so a fixed
       multi-replica install (min == max == 2) still gets a PDB; gating on
       scaling alone would skip it and let a node drain evict every replica. */ -}}
{{- define "stageset.multiReplica" -}}
{{- if or (gt (.Values.replicas.max | int) 1) (gt (.Values.replicas.min | int) 1) -}}true{{- end -}}
{{- end -}}
