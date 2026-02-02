resource "kubernetes_namespace" "argo" {
  metadata {
    name = var.argo-ns
  }
}

resource "helm_release" "argo" {
  depends_on = [kubernetes_namespace.argo]
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "8.6.4"
  name       = "argocd"
  namespace  = var.argo-ns
  values = [
    file("${path.cwd}/helm-values-argo.yaml")
  ]
  wait          = true
  wait_for_jobs = true
}

resource "kubernetes_secret_v1" "argo_config_repo" {
  metadata {
    name      = "argo-config-repo"
    namespace = var.argo-ns
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }
  data = {
    name = "argocd-config"
    type = "git"
    url : var.repo-url
    username : var.gh-user
    password : var.gh-pat
  }
}

resource "null_resource" "wait_for_argocd" {
  depends_on = [helm_release.argo]

  provisioner "local-exec" {
    command = "until kubectl --kubeconfig=${path.module}/../kubeconfig-homelab get crd applications.argoproj.io; do sleep 5; done"
  }
}

resource "kubectl_manifest" "argocd_applications_parent" {
  depends_on = [
    kubernetes_secret_v1.argo_config_repo,
    null_resource.wait_for_argocd
  ]
  yaml_body = yamlencode({
    apiVersion : "argoproj.io/v1alpha1",
    kind : "Application",
    metadata : {
      name : "all-apps",
      namespace : var.argo-ns
    },
    spec : {
      project : "default",
      source : {
        repoURL : var.repo-url,
        path : "kubernetes/applications",
        targetRevision : "HEAD",
        directory : {
          recurse : true,
        },
      },
      destination : {
        server : "https://kubernetes.default.svc",
        namespace : "default",
      },
      syncPolicy : {
        automated : {
          prune : true,
          selfHeal : true,
        },
        syncOptions : ["CreateNamespace=true"],
      },
    },
  })
}
