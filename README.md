# ArgoCD GitOps Monorepo

A production-ready GitOps platform built on ArgoCD, implementing the **App of Apps** pattern with **ApplicationSets** and a hierarchical Helm values system. Charts live in a separate repository; this repo is purely configuration and deployment intent.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Purpose](#purpose)
- [Architecture](#architecture)
  - [App of Apps Bootstrap](#app-of-apps-bootstrap)
  - [ApplicationSet with Git Generator](#applicationset-with-git-generator)
  - [Hierarchical Values](#hierarchical-values)
  - [Per-Cluster App Configuration](#per-cluster-app-configuration)
- [Repository Structure](#repository-structure)
- [How a Company Uses This](#how-a-company-uses-this)
- [Promotion Pipelines — Kargo and Argo Rollouts](#promotion-pipelines--kargo-and-argo-rollouts)
- [Deploying a New App](#deploying-a-new-app)
- [Adding a New Cluster](#adding-a-new-cluster)
- [Enabling and Disabling Apps](#enabling-and-disabling-apps)
- [ArgoCD Version](#argocd-version)

---

## Quick Start

### Prerequisites

- [minikube](https://minikube.sigs.k8s.io/)
- [helm](https://helm.sh/) >= 3.x
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [argocd CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) (optional but useful)

### Bootstrap locally (minikube)

```bash
# 1. Clone the repo
git clone https://github.com/rhysmcneill/poc-argocd-monorepo
cd poc-argocd-monorepo

# 2. Install ArgoCD and seed the root Application
make bootstrap

# 3. Open the ArgoCD UI
make ui
# Username: admin  |  Password: make password
```

After `make bootstrap`, ArgoCD takes over — all subsequent changes are driven by pushing to `main`.

### Useful make targets

| Command | Description |
|---|---|
| `make bootstrap` | Install ArgoCD on minikube and seed the root Application |
| `make ui` | Port-forward ArgoCD UI to `http://localhost:8080` |
| `make password` | Print the initial admin password |
| `make status` | Show status of all ArgoCD Applications |
| `make sync` | Force a sync of the root Application |
| `make clean` | Uninstall ArgoCD from minikube |

### Bootstrap on a remote cluster (CI/CD)

Push to `main` and trigger the GitHub Actions workflow manually:

**Actions → Bootstrap ArgoCD → Run workflow → select environment**

The workflow installs ArgoCD via Helm and applies the root Application. Required secrets per environment: `KUBECONFIG_DEV`, `KUBECONFIG_STAGING`, `KUBECONFIG_PROD`.

---

## Purpose

This repository is the single source of truth for **what gets deployed, where, and with what configuration** across all clusters and environments. It answers three questions declaratively in git:

1. **Which apps run on which clusters?** — via `app-config.yaml` files
2. **With what configuration?** — via a layered Helm values hierarchy
3. **From which chart repository?** — via `chartRepoURL` and `chartPath` in each `app-config.yaml`

No direct `kubectl` or `helm install` commands are ever run against clusters. Every change is a git commit.

---

## Architecture

### App of Apps Bootstrap

The system is seeded by a single `kubectl apply` (automated by the bootstrap script/workflow). After that, ArgoCD manages itself.

```
kubectl apply -f bootstrap/root-app.yaml   ← one-time seed
        │
        ▼
   root Application  (watches bootstrap/)
        │
        ├── projects-app  →  projects/   →  AppProjects (dev, staging, prod)
        │
        └── appsets-app   →  appsets/    →  ApplicationSet (apps.yaml)
                                                   │
                                                   │  git generator scans:
                                                   │  config/envs/*/*/*/*/app-config.yaml
                                                   │
                                                   ├── observability-dev-eks-local-dev
                                                   ├── example-app-dev-eks-local-dev
                                                   └── ... (one per app-config.yaml)
```

The root Application uses `prune: true` and `selfHeal: true`, meaning:
- Adding a file to `bootstrap/` → ArgoCD picks it up automatically
- Removing a file → ArgoCD prunes the resource
- Any drift from git → ArgoCD corrects it

### ApplicationSet with Git Generator

A single `ApplicationSet` (`appsets/apps.yaml`) generates all cluster Applications. It uses a **git files generator** that scans for `app-config.yaml` files:

```yaml
generators:
  - git:
      files:
        - path: "config/envs/*/*/*/*/app-config.yaml"
```

Each `app-config.yaml` file found produces one `Application` object in ArgoCD. The file's YAML content becomes the template variables (`appName`, `env`, `region`, `cluster`, `server`, `chartRepoURL`, etc.).

**Why a single ApplicationSet rather than one per app?**
- Adding a new app = drop one `app-config.yaml` file. No changes to the AppSet.
- Adding a new cluster = same. The generator discovers it automatically.
- The AppSet itself never needs to change for routine operations.

### Hierarchical Values

Every generated Application resolves Helm values from a layered hierarchy. Later layers override earlier ones (standard Helm merge semantics):

```
charts/<app>/values.yaml                                  ← chart author defaults (lowest priority)
    ↓
config/base/values.yaml                                   ← global platform overrides
    ↓
config/envs/<env>/values.yaml                             ← environment overrides
    ↓
config/envs/<env>/<region>/values.yaml                    ← region overrides (ECR repos, AZs, etc.)
    ↓
config/envs/<env>/<region>/<cluster>/values.yaml          ← cluster-wide shared overrides
    ↓
config/envs/<env>/<region>/<cluster>/<app>/values.yaml    ← per-app cluster overrides (highest priority)
```

This is implemented using ArgoCD's multi-source Application feature. Source 1 is the Helm chart (from the charts repo). Source 2 is this repo, referenced as `$values`, making all `config/` paths available as `valueFiles`. Missing files at any level are silently skipped (`ignoreMissingValueFiles: true`), so intermediate levels are optional.

**Practical examples of what goes at each level:**

| Level | Examples |
|---|---|
| `base/` | Default replica counts, resource limits, log levels |
| `env/` | Environment-specific feature flags, debug settings |
| `region/` | ECR registry URLs, regional endpoints, availability zones |
| `cluster/` | Node selectors, cluster-specific ingress classes |
| `cluster/<app>/` | App-specific overrides unique to that cluster |

### Per-Cluster App Configuration

The `app-config.yaml` file is the deployment intent document for a single app on a single cluster:

```yaml
# config/envs/dev/eu-west-1/eks-local-dev/observability/app-config.yaml
autoSync: true           # true = deployed, false = resources pruned

appName: observability
env: dev
region: eu-west-1
cluster: eks-local-dev
server: https://kubernetes.default.svc

chartRepoURL: https://github.com/rhysmcneill/poc-helm-monorepo
chartPath: charts/observability
chartVersion: HEAD       # pin to a tag or SHA for production
namespace: observability
```

Charts live in a **separate repository** (`poc-helm-monorepo`). This separates the deployment lifecycle from the chart development lifecycle — chart authors can iterate on charts independently, and this repo controls when and where those chart versions are promoted.

---

## Repository Structure

```
poc-argocd-monorepo/
│
├── bootstrap/                        # App of Apps entry point
│   ├── root-app.yaml                 # Applied once to seed ArgoCD
│   ├── projects-app.yaml             # ArgoCD Application → manages projects/
│   └── appsets-app.yaml             # ArgoCD Application → manages appsets/
│
├── projects/                         # ArgoCD AppProject definitions
│   ├── dev.yaml
│   ├── staging.yaml
│   └── prod.yaml
│
├── appsets/                          # ApplicationSet definitions
│   └── apps.yaml                     # Single AppSet — generates all cluster Applications
│
├── charts/                           # Local charts (utility only)
│   └── empty/                        # Zero-resource chart used when autoSync: false
│
├── config/                           # Helm values hierarchy
│   ├── base/
│   │   └── values.yaml               # Global defaults
│   └── envs/
│       ├── dev/
│       │   ├── values.yaml           # Dev env overrides
│       │   └── eu-west-1/
│       │       ├── values.yaml       # Region overrides
│       │       └── eks-local-dev/
│       │           ├── cluster.yaml  # Cluster reference metadata
│       │           ├── values.yaml   # Cluster-wide shared overrides
│       │           ├── observability/
│       │           │   ├── app-config.yaml   # Deployment intent
│       │           │   └── values.yaml       # App-specific overrides
│       │           └── example-app/
│       │               ├── app-config.yaml
│       │               └── values.yaml
│       ├── staging/
│       └── prod/
│
├── example/
│   └── my-app/
│       └── app-config.yaml           # Annotated reference template
│
├── scripts/
│   └── bootstrap-minikube.sh
│
├── .github/workflows/
│   └── bootstrap.yaml                # CI bootstrap for remote clusters
│
└── Makefile                          # Local dev convenience targets
```

---

## How a Company Uses This

### Platform team responsibilities

The platform team owns this repository and manages:
- The `config/base/` and `config/envs/<env>/` and `config/envs/<env>/<region>/` values files (global platform standards)
- The `projects/` AppProject definitions (RBAC boundaries)
- The `appsets/apps.yaml` ApplicationSet (the generator logic)
- The bootstrap scripts and CI workflows
- Cluster registration (`cluster.yaml` files and ArgoCD cluster secrets)

### Development team responsibilities

Development teams interact only with their slice of `config/`:

```
config/envs/<env>/<region>/<cluster>/<their-app>/
├── app-config.yaml    ← enable/disable, pin chart version
└── values.yaml        ← their app's configuration for this cluster
```

They open PRs to this repo when they want to:
- Deploy their app to a new cluster (add `app-config.yaml`)
- Change configuration (edit `values.yaml`)
- Pin to a specific chart version (bump `chartVersion`)
- Disable an app (set `autoSync: false`)

### RBAC model

Each environment maps to an ArgoCD `AppProject` which restricts:
- Which clusters the project can deploy to
- Which repos are permitted as chart sources
- Which roles (developer, CI deployer) can trigger syncs

Developers can sync dev freely. Staging and prod require the CI deployer role, enforcing the promotion pipeline.

### Onboarding a new application

1. The chart is authored and merged into the charts repository (`poc-helm-monorepo`)
2. The team opens a PR here creating `config/envs/dev/<region>/<cluster>/<app>/app-config.yaml` with `autoSync: true`
3. PR merged → ArgoCD deploys to dev automatically
4. Team promotes through environments by creating `app-config.yaml` files in staging and prod directories (see [Promotion Pipelines](#promotion-pipelines--kargo-and-argo-rollouts))

---

## Promotion Pipelines — Kargo and Argo Rollouts

This repo's structure is purpose-built for integration with promotion tools.

### How Kargo fits in

[Kargo](https://kargo.akuity.io/) is a progressive delivery tool that automates the promotion of changes across environments. It watches for new chart versions (or image tags, OCI artifacts, etc.) and opens PRs or directly commits to repos like this one.

In this setup, Kargo would:

1. **Detect** a new chart version published to the charts repo (e.g., `v1.2.0` tagged on `poc-helm-monorepo`)
2. **Promote to dev** — commit a bump to `chartVersion: v1.2.0` in `config/envs/dev/.../app-config.yaml`
3. **Verify** — wait for the ArgoCD Application to become `Healthy` and `Synced`
4. **Promote to staging** — commit the same bump to the staging `app-config.yaml`
5. **Verify staging** — run smoke tests, integration tests, or wait for manual approval
6. **Promote to prod** — commit to the prod `app-config.yaml`

The `chartVersion` field in each cluster's `app-config.yaml` is the exact integration point:

```yaml
# dev  → chartVersion: v1.2.0   (Kargo promoted here first)
# staging → chartVersion: v1.1.5 (awaiting promotion)
# prod    → chartVersion: v1.1.0 (stable, not yet promoted)
```

This gives complete visibility into what version is running where, entirely in git history.

### How Argo Rollouts fits in

[Argo Rollouts](https://argoproj.github.io/argo-rollouts/) operates at the Kubernetes workload level (canary, blue/green strategies) rather than the GitOps config level. It complements this repo by:

- Controlling how a new chart version is rolled out within a cluster (e.g., 10% canary → 50% → 100%)
- Providing automatic rollback if analysis checks fail
- Integrating with Prometheus/Datadog metrics to gate promotion

The Rollout strategy is defined in the chart's templates (in `poc-helm-monorepo`). This repo controls the `chartVersion` that contains those Rollout specs. When Kargo promotes a new version here, Argo Rollouts takes over within the cluster to manage the actual rollout safely.

**Combined flow:**

```
Chart repo tags v1.2.0
        │
        ▼
Kargo detects new version
        │
        ├── Bumps chartVersion in dev/app-config.yaml → ArgoCD syncs → Argo Rollouts runs canary
        │                                                                       │
        │                                               Analysis passes ────────┘
        │
        ├── Kargo promotes to staging/app-config.yaml → same flow
        │
        └── Manual approval gate → Kargo promotes to prod/app-config.yaml
```

### Why this structure makes promotions clean

- **Each environment's version is explicit in git** — no "what's running in prod?" questions
- **Promotion = a git commit** — reviewable, auditable, revertable
- **Failed promotion = revert the commit** — immediate rollback
- **No kubectl or helm commands in the pipeline** — ArgoCD handles apply, Kargo handles the commits

---

## Deploying a New App

Copy the annotated example and fill in the values:

```bash
# Replace <env>, <region>, <cluster>, <app> with real values
mkdir -p config/envs/<env>/<region>/<cluster>/<app>

# Copy the reference template
cp example/my-app/app-config.yaml config/envs/<env>/<region>/<cluster>/<app>/app-config.yaml

# Edit it — set autoSync, appName, chartRepoURL, chartPath, chartVersion, namespace

# Optionally add app-specific values
touch config/envs/<env>/<region>/<cluster>/<app>/values.yaml

git add .
git commit -m "feat: deploy <app> to <cluster>"
git push
```

ArgoCD detects the new `app-config.yaml` within its next polling interval (default 3 minutes) and creates the Application automatically.

---

## Adding a New Cluster

1. Register the cluster with ArgoCD:
   ```bash
   argocd cluster add <context-name> --name <cluster-name>
   ```

2. Create the cluster directory and reference file:
   ```bash
   mkdir -p config/envs/<env>/<region>/<cluster>
   ```

   ```yaml
   # config/envs/<env>/<region>/<cluster>/cluster.yaml
   env: <env>
   region: <region>
   cluster: <cluster>
   server: https://<cluster-api-endpoint>
   ```

3. Create `app-config.yaml` files for whichever apps should run on the new cluster.

4. Push — ArgoCD picks up all new `app-config.yaml` files automatically.

---

## Enabling and Disabling Apps

| Intent | Action |
|---|---|
| Deploy app to cluster | Create `app-config.yaml` with `autoSync: true` |
| Pause deploys (keep resources running) | Set `autoSync: false` — syncs stop, existing resources kept |
| Clean up resources (keep Application visible) | Set `autoSync: false` — redirects to empty chart, resources pruned |
| Remove Application from ArgoCD entirely | Delete the `app-config.yaml` file |

> **Note:** Setting `autoSync: false` redirects the Application to an intentionally empty Helm chart (`charts/empty/`). ArgoCD syncs this empty chart with `prune: true`, which deletes all previously deployed Kubernetes resources. The Application object remains visible in the ArgoCD UI with 0 managed resources.

---

## ArgoCD Version

This repo targets **ArgoCD 3.5** (chart `10.1.4` + image override). ArgoCD 3.5 introduces:

- **ApplicationSet UI** — view, filter, and preview ApplicationSets natively in the web UI (`/applicationsets` route). Alpha feature.
- **Helm 4 support** — native compatibility with Helm 4 toolchain
- **Multi-source Applications** — required for the `$values` reference pattern used in this repo (requires ArgoCD ≥ 2.6)

The ApplicationSet UI is particularly useful with this repo — you can open the `apps` ApplicationSet in the UI, click **Preview**, and see exactly which Applications would be generated from the current `app-config.yaml` files before pushing.

> ArgoCD 3.5 GA is targeted for **August 4, 2026**. Until then, the bootstrap installs chart `10.1.4` with image `v3.5.0-rc2`. Update `ARGOCD_IMAGE` in the `Makefile` and `ARGOCD_IMAGE_TAG` in `.github/workflows/bootstrap.yaml` once GA is released.
