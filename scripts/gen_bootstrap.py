"""
Generates gitops/bootstrap/*.yaml (the ApplicationSets). Edit THIS file and re-run,
rather than hand-editing 13 near-identical ApplicationSets:

    python3 scripts/gen_bootstrap.py

Pattern for every add-on (matrix generator):
  1. git files generator reads gitops/envs/<env>/addons.yaml  -> versions + .path.basename = env
  2. cluster generator selects clusters with label env=<that env> (and role)
  -> one Application per (add-on, cluster), pinned to that environment's version.
"""

import pathlib

import yaml

REPO = "https://github.com/poornarallapalli/eks-llm-lab.git"
REV = "main"
ENV = "{{.path.basename}}"  # from the git files generator
OUT = pathlib.Path(__file__).resolve().parent.parent / "gitops" / "bootstrap"

RETRY = {"limit": 20, "backoff": {"duration": "15s", "factor": 2, "maxDuration": "5m"}}
ISTIO_WEBHOOK_IGNORE = [
    {
        "group": "admissionregistration.k8s.io",
        "kind": "ValidatingWebhookConfiguration",
        "jqPathExpressions": [".webhooks[]?.failurePolicy", ".webhooks[]?.clientConfig.caBundle"],
    },
    {
        "group": "admissionregistration.k8s.io",
        "kind": "MutatingWebhookConfiguration",
        "jqPathExpressions": [".webhooks[]?.clientConfig.caBundle"],
    },
]


def values_source():
    return {"repoURL": REPO, "targetRevision": REV, "ref": "values"}


def appset(name, role, sources, namespace, sync_options=None, ignore=None,
           server_side_diff=False, extra_labels=None):
    selector = {"role": role, "env": ENV}
    selector.update(extra_labels or {})
    metadata = {"name": f"{name}-{{{{.name}}}}", "labels": {"addon": name, "env": ENV}}
    if server_side_diff:
        # diff against what the API server would actually persist (defaults, operator/webhook
        # mutations) -> avoids permanent OutOfSync on operator-managed CRs
        metadata["annotations"] = {"argocd.argoproj.io/compare-options": "ServerSideDiff=true"}
    spec = {
        "project": "default",
        "destination": {"server": "{{.server}}", "namespace": namespace},
        "syncPolicy": {
            "automated": {"prune": True, "selfHeal": True},
            "syncOptions": ["CreateNamespace=true"] + (sync_options or []),
            "retry": RETRY,
        },
    }
    if len(sources) == 1:
        spec["source"] = sources[0]
    else:
        spec["sources"] = sources
    if ignore:
        spec["ignoreDifferences"] = ignore
        spec["syncPolicy"]["syncOptions"].append("RespectIgnoreDifferences=true")
    return {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "ApplicationSet",
        "metadata": {"name": name, "namespace": "argocd"},
        "spec": {
            "goTemplate": True,
            "goTemplateOptions": ["missingkey=error"],
            "generators": [{
                "matrix": {"generators": [
                    {"git": {"repoURL": REPO, "revision": REV,
                             "files": [{"path": "gitops/envs/*/addons.yaml"}]}},
                    {"clusters": {"selector": {"matchLabels": selector}}},
                ]}
            }],
            "template": {"metadata": metadata, "spec": spec},
        },
    }


def chart(repo, chart_name, version_key, release, value_files=(), values_object=None):
    helm = {"releaseName": release, "ignoreMissingValueFiles": True}
    if value_files:
        helm["valueFiles"] = list(value_files)
    if values_object:
        helm["valuesObject"] = values_object
    return {"repoURL": repo, "chart": chart_name, "targetRevision": f"{{{{.{version_key}}}}}", "helm": helm}


def local_chart(path, release, values_object=None):
    helm = {"releaseName": release, "ignoreMissingValueFiles": True,
            "valueFiles": ["values.yaml", f"values-{ENV}.yaml"]}
    if values_object:
        helm["valuesObject"] = values_object
    return {"repoURL": REPO, "targetRevision": REV, "path": path, "helm": helm}


CLUSTER = '{{index .metadata.annotations "cluster_name"}}'
REGION = '{{index .metadata.annotations "aws_region"}}'
AMP_WRITE = '{{index .metadata.annotations "amp_remote_write_url"}}'
AMP_QUERY = '{{index .metadata.annotations "amp_query_url"}}'

KPS_REMOTE = {
    "prometheus": {"prometheusSpec": {
        "externalLabels": {"cluster": CLUSTER, "env": ENV},
        "remoteWrite": [{
            "url": AMP_WRITE,
            "sigv4": {"region": REGION},  # signed with the Pod Identity role (aps:RemoteWrite)
            "queueConfig": {"capacity": 10000, "maxShards": 10, "maxSamplesPerSend": 2000},
        }],
    }}
}

spokes = [
    # Day-2 node capacity definitions for this cluster (needs only Karpenter CRDs from Terraform)
    appset("karpenter-nodepools", "spoke",
           [local_chart("gitops/charts/karpenter-nodepools", "karpenter-nodepools",
                        {"clusterName": CLUSTER})],
           "kube-system"),
    # Calico policy engine (Tigera operator). The operator owns the DaemonSets it creates.
    appset("calico", "spoke",
           [chart("https://docs.tigera.io/calico/charts", "tigera-operator", "calico", "calico",
                  ["$values/gitops/addons/calico/values-common.yaml",
                   f"$values/gitops/addons/calico/values-{ENV}.yaml"]),
            values_source()],
           "tigera-operator", ["ServerSideApply=true"], server_side_diff=True),
    # Istio: base (CRDs) -> istiod -> gateway. Retries handle the ordering.
    appset("istio-base", "spoke",
           [chart("https://istio-release.storage.googleapis.com/charts", "base", "istio", "istio-base",
                  values_object={"defaultRevision": "default"})],
           "istio-system", ["ServerSideApply=true"], ignore=ISTIO_WEBHOOK_IGNORE),
    appset("istiod", "spoke",
           [chart("https://istio-release.storage.googleapis.com/charts", "istiod", "istio", "istiod",
                  ["$values/gitops/addons/istio/istiod-common.yaml",
                   f"$values/gitops/addons/istio/istiod-{ENV}.yaml"]),
            values_source()],
           "istio-system", ["ServerSideApply=true"], ignore=ISTIO_WEBHOOK_IGNORE),
    appset("istio-gateway", "spoke",
           [chart("https://istio-release.storage.googleapis.com/charts", "gateway", "istio",
                  "istio-ingressgateway",
                  ["$values/gitops/addons/istio/gateway-common.yaml",
                   f"$values/gitops/addons/istio/gateway-{ENV}.yaml"]),
            values_source()],
           "istio-ingress"),
    # Namespaces + Calico baseline policies + Istio mTLS/telemetry (needs Calico + Istio CRDs)
    appset("platform-baseline", "spoke",
           [local_chart("gitops/charts/platform-baseline", "platform-baseline")],
           "llm", ["SkipDryRunOnMissingResource=true"]),
    # Metrics -> Amazon Managed Prometheus
    appset("monitoring", "spoke",
           [chart("https://prometheus-community.github.io/helm-charts", "kube-prometheus-stack",
                  "kubePrometheusStack", "kps",
                  ["$values/gitops/addons/kube-prometheus-stack/values-common.yaml",
                   f"$values/gitops/addons/kube-prometheus-stack/values-{ENV}.yaml"],
                  KPS_REMOTE),
            values_source()],
           "monitoring", ["ServerSideApply=true"]),
    # GPU queueing for teams
    appset("kueue", "spoke",
           [chart("registry.k8s.io/kueue/charts", "kueue", "kueue", "kueue")],
           "kueue-system", ["ServerSideApply=true"]),
    appset("kueue-config", "spoke",
           [local_chart("gitops/charts/kueue-config", "kueue-config")],
           "kueue-system", ["SkipDryRunOnMissingResource=true"]),
    # Code-execution sandboxes
    appset("agent-sandbox", "spoke",
           [{"repoURL": "https://github.com/kubernetes-sigs/agent-sandbox.git",
             "targetRevision": "{{.agentSandbox}}", "path": "helm",
             "helm": {"releaseName": "agent-sandbox", "valuesObject": {
                 "image": {"tag": "{{.agentSandbox}}"},
                 "controller": {"extensions": True},
                 "metrics": {"serviceMonitor": {"enabled": True}},
             }}}],
           "agent-sandbox-system", ["ServerSideApply=true", "SkipDryRunOnMissingResource=true"]),
    appset("sandbox-platform", "spoke",
           [local_chart("gitops/charts/sandbox-platform", "sandbox-platform")],
           "sandboxes", ["SkipDryRunOnMissingResource=true"]),
]

hub = [
    appset("hub-monitoring", "hub",
           [chart("https://prometheus-community.github.io/helm-charts", "kube-prometheus-stack",
                  "kubePrometheusStack", "kps",
                  ["$values/gitops/addons/kube-prometheus-stack/values-common.yaml",
                   "$values/gitops/addons/kube-prometheus-stack/values-hub.yaml"],
                  {**KPS_REMOTE, "grafana": {"additionalDataSources": [{
                      "name": "Amazon Managed Prometheus",
                      "uid": "amp",
                      "type": "prometheus",
                      "isDefault": True,
                      "url": AMP_QUERY,
                      "jsonData": {"sigV4Auth": True, "sigV4AuthType": "default",
                                   "sigV4Region": REGION, "httpMethod": "POST"},
                  }]}}),
            values_source()],
           "monitoring", ["ServerSideApply=true"]),
]

# Applications: one Application per GPU spoke, reading that env's values file.
apps = [{
    "apiVersion": "argoproj.io/v1alpha1",
    "kind": "ApplicationSet",
    "metadata": {"name": "app-vllm", "namespace": "argocd"},
    "spec": {
        "goTemplate": True,
        "goTemplateOptions": ["missingkey=error"],
        "generators": [{"clusters": {"selector": {"matchLabels": {"role": "spoke", "gpu": "true"}}}}],
        "template": {
            "metadata": {"name": "vllm-{{.name}}", "labels": {"app": "vllm"}},
            "spec": {
                "project": "default",
                "source": {
                    "repoURL": REPO, "targetRevision": REV, "path": "apps/vllm/chart",
                    "helm": {"releaseName": "vllm", "valueFiles": [
                        "values.yaml", '../envs/{{index .metadata.labels "env"}}/values.yaml']},
                },
                "destination": {"server": "{{.server}}", "namespace": "llm"},
                "syncPolicy": {"automated": {"prune": True, "selfHeal": True},
                               "syncOptions": ["SkipDryRunOnMissingResource=true"],
                               "retry": RETRY},
            },
        },
    },
}]

HEADER = "# GENERATED by scripts/gen_bootstrap.py. Edit the script, then re-run it.\n"


def write(fname, docs):
    text = HEADER + "".join("---\n" + yaml.safe_dump(d, sort_keys=False, width=200) for d in docs)
    (OUT / fname).write_text(text)
    print(f"wrote {OUT / fname} ({len(docs)} ApplicationSets)")


OUT.mkdir(parents=True, exist_ok=True)
write("spoke-addons.yaml", spokes)
write("hub-addons.yaml", hub)
write("apps.yaml", apps)
