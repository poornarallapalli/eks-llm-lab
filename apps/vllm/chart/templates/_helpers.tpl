{{- define "vllm.labels" -}}
app: {{ .Values.name }}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/component: model-server
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
{{- end }}
