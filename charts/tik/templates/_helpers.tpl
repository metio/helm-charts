{{- /*
SPDX-FileCopyrightText: The helm-charts Authors
SPDX-License-Identifier: 0BSD
*/ -}}

{{- /* The component label of the pod that serves the HTTP board — the `tik
       backend` supervisor in backend mode, the standalone `tik serve` board in
       split mode. The Service and NetworkPolicy select on this so they target
       whichever mode is active. */ -}}
{{- define "tik.httpComponent" -}}
{{- if eq .Values.mode "backend" }}backend{{ else }}board{{ end -}}
{{- end -}}

{{- /* The mail-ingest container, shared by the IMAP --watch Deployment and the
       POP3 CronJob. Expects a dict: root (the chart context $), args (the tik
       argument list). It signs events, so it mounts the store read-write, the
       rendered config ConfigMap at /etc/tik, the signing key at /etc/tik/keys
       (TIK_KEY), and — when set — the mailbox password Secret at
       /etc/tik/secrets so the config's {:file …} spec resolves it. */ -}}
{{- define "tik.ingestContainer" -}}
- name: ingest
  image: "{{ .root.Values.image.registry }}/{{ .root.Values.image.repository }}:{{ default .root.Chart.AppVersion .root.Values.image.tag }}"
  imagePullPolicy: {{ .root.Values.image.pullPolicy }}
  args:
    {{- toYaml .args | nindent 4 }}
  env:
    - name: TIK_ROOT
      value: /var/lib/tik
    - name: TIK_KEY
      value: /etc/tik/keys/{{ .root.Values.ingest.signingKeySecret.keyFile }}
  volumeMounts:
    - name: store
      mountPath: /var/lib/tik
    - name: config
      mountPath: /etc/tik/tik-ingest.edn
      subPath: tik-ingest.edn
      readOnly: true
    - name: signing-key
      mountPath: /etc/tik/keys
      readOnly: true
    {{- if .root.Values.ingest.passwordSecret.name }}
    - name: mailbox-password
      mountPath: /etc/tik/secrets
      readOnly: true
    {{- end }}
    - name: tmp
      mountPath: /tmp
  resources:
    requests:
      cpu: {{ .root.Values.ingest.resources.cpu }}
      memory: {{ .root.Values.ingest.resources.memory }}
      ephemeral-storage: {{ .root.Values.ingest.resources.ephemeralStorage }}
    limits:
      cpu: {{ .root.Values.ingest.resources.cpu }}
      memory: {{ .root.Values.ingest.resources.memory }}
      ephemeral-storage: {{ .root.Values.ingest.resources.ephemeralStorage }}
  securityContext:
    runAsNonRoot: true
    runAsGroup: 12345
    runAsUser: 12345
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
{{- end -}}

{{- /* The volumes the ingest container mounts. Expects the chart context $. */ -}}
{{- define "tik.ingestVolumes" -}}
- name: store
  {{- if .Values.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ .Release.Name }}-store
  {{- else }}
  emptyDir:
    sizeLimit: {{ .Values.persistence.size }}
  {{- end }}
- name: config
  configMap:
    name: {{ .Release.Name }}-ingest
- name: signing-key
  secret:
    secretName: {{ required "ingest.signingKeySecret.name is required when ingest.enabled is true" .Values.ingest.signingKeySecret.name }}
    defaultMode: 0400
    # optional so a missing secret does not block the pod at start (the
    # watcher retries and logs); the Secret must still exist for real signing.
    optional: true
{{- if .Values.ingest.passwordSecret.name }}
- name: mailbox-password
  secret:
    secretName: {{ .Values.ingest.passwordSecret.name }}
    defaultMode: 0400
    optional: true
{{- end }}
- name: tmp
  emptyDir:
    sizeLimit: 64Mi
{{- end -}}
