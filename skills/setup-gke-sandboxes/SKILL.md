---
name: setup-gke-sandboxes
description: Set up gke-sandboxes in a Google Cloud project and connect a backend to it. Use when asked to deploy, install, try, verify or tear down gke-sandboxes, or to give agents persistent gVisor sandboxes on GKE.
---

# Set up gke-sandboxes

You are setting up gke-sandboxes for the user: a GKE cluster that runs each agent session in its own gVisor pod, saves its files to Cloud Storage when it sleeps, and restores them when it wakes. Run the steps in order and stop at the first one that fails.

## Rules

- Ask before anything that costs money or deletes something: `terraform apply`, `terraform destroy`, and deleting sandboxes.
- Use a test project unless the user names another one and confirms it. Never point this at a project that serves production traffic without that confirmation.
- Never print access tokens or put them in files.
- Report what you ran and what it returned. If a step fails, show the error and say what you will try next.

## 1. Ask the user

Get these before running anything:

| Need | Used as | Note |
| --- | --- | --- |
| Google Cloud project ID | `TF_VAR_project_id` | Billing must be enabled. |
| Region | `TF_VAR_region` | Default `us-central1`. It must support GKE Pod snapshots with gVisor. |
| Zone | `TF_VAR_zone` | Default `us-central1-a`. It must be in the region. The cluster is zonal, so GKE's free tier credit covers its fee. |
| Their Google account or group | `TF_VAR_operator_member` | Form `user:name@example.com`. It may impersonate the controller service account. |
| Most sandbox machines to run | `TF_VAR_max_sandbox_nodes` | Default `1`, which keeps the cluster within 8 vCPU. |

Tell them what it costs while it runs, at Iowa list prices: one `e2-highmem-4` sandbox machine at about $0.18 an hour, one `e2-standard-2` system machine at about $0.07, plus disks and Cloud NAT. The free tier credit covers the $0.10 cluster fee for one zonal cluster per billing account. That is roughly $0.28 an hour, or about $7 a day, until they tear it down. See "Small trial" in the README.

## 2. Check the tools

```sh
bun --version        # 1.4.4 or later
terraform version    # 1.15 or later
gcloud --version
kubectl version --client
gke-gcloud-auth-plugin --version
gcloud auth list
gcloud auth application-default print-access-token >/dev/null && echo adc-ok
```

If a tool is missing, tell the user how to install it and wait. If either credential check fails, ask the user to run `gcloud auth login --update-adc`. Do not try to sign in for them.

## 3. Deploy

The Terraform and the verifier live in the repository. If you are not already in a checkout of it, get one, then run everything from its root in one shell so the variables carry over.

```sh
# git clone <this repository's URL> && cd gke-sandboxes

export TF_VAR_project_id=<project>
export TF_VAR_operator_member=user:<email>
export TF_VAR_region=us-central1
export TF_VAR_zone=us-central1-a

bun install
terraform -chdir=infra init
terraform -chdir=infra plan
```

Show the user the plan summary and get their go-ahead, then:

```sh
terraform -chdir=infra apply
export KUBECONFIG="$(mktemp)"
gcloud container clusters get-credentials sandboxes --dns-endpoint \
  --project="$TF_VAR_project_id" --location="$TF_VAR_zone"
terraform -chdir=infra output -raw manifests | kubectl apply -f -
```

`apply` takes 10 to 15 minutes. It creates the cluster, a system node pool and a gVisor sandbox node pool, a private network with Cloud NAT, a snapshot bucket, and a controller service account. The manifests add the `sandboxes` namespace, network policies, the snapshot policy, access for the controller, a placeholder deployment that can keep spare capacity (0 replicas by default), and a sweeper in `sandbox-system` that puts idle sandboxes to sleep.

Use the separate `KUBECONFIG` as shown. It keeps the user's own kubectl contexts untouched.

## 4. Verify

```sh
bun examples/verify.ts \
  --endpoint "$(terraform -chdir=infra output -raw endpoint)" \
  --controller "$(terraform -chdir=infra output -raw controller)"
```

It creates a sandbox, writes a file, puts the sandbox to sleep, waits for the pod to go, wakes it, checks the file, and deletes it. Success prints JSON with one sample:

```json
{ "samples": [{ "createMs": 3200, "sleepAndRemoveMs": 4500, "wakeMs": 3500 }] }
```

Times within a few seconds of those are normal on a warm node. The first run on a new node is slower because it pulls the image. Tell the user the three numbers.

## 5. Connect a backend

Install the client in the user's backend. It runs on Node.js 22 or later and on Bun.

```sh
npm install @getenergy/gke-sandboxes google-auth-library
```

```ts
import { GkeSandboxes, KubernetesApi } from '@getenergy/gke-sandboxes';
import { GoogleAuth } from 'google-auth-library';

const auth = new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] });
const sandboxes = new GkeSandboxes(
  // The URL is `terraform -chdir=infra output -raw endpoint`.
  new KubernetesApi(process.env.GKE_SANDBOX_API_URL!, async () => (await auth.getAccessToken())!),
  { namespace: 'sandboxes', serviceAccount: 'sandbox', image: 'docker.io/library/debian:bookworm-slim' },
);

const { sandbox, touch } = await sandboxes.acquire('session-42', AbortSignal.timeout(300_000));
const { exitCode, result } = await sandbox.process.executeCommand('uname -a');
```

What the backend must do:

- **Run as the controller service account.** Its email is `terraform -chdir=infra output -raw controller`. Attach it to the service (Cloud Run, GKE, Compute Engine) or impersonate it. Only that account has access to the `sandboxes` namespace.
- **Choose sandbox IDs itself.** An ID is a DNS label of up to 56 characters. The backend checks that the user may open it. Anyone holding the client can open any sandbox in the namespace.
- **Report use.** Call `touch()` every minute or so while an agent works in the sandbox.
- **Leave sleeping to the sweeper.** The quickstart deploys one, which puts a sandbox to sleep after five idle minutes. If the backend passes `drain`, it must call `sandboxes.sleepUnused()` itself on a schedule, and the deployment needs `TF_VAR_sweeper_enabled=false`.
- **Delete what is finished.** Call `sandboxes.delete(id)` when a session's files can be discarded.

Keep these in mind when choosing an image and writing to the sandbox:

- The image needs a POSIX shell and a writable `/var/tmp`. Pin its digest in production.
- Sleep saves the root filesystem. `/tmp` is scratch and comes back empty.
- Wake time and snapshot size grow with the number of files. Point package caches at `/tmp`.

[docs/client.md](../../docs/client.md) covers `drain`, `runtime`, `boot`, `resources` and warm pools.

## 6. Size it for real use (optional)

The defaults are one `e2-highmem-4` machine with sandboxes that reserve 0.25 vCPU, 1 GiB and 4 GiB of disk, about 12 per machine, or 6 agent-sized ones (see "Small trial" in the README). For faster machines and denser packing, see "Deploy on C4D" in [docs/deploy.md](../../docs/deploy.md#deploy-on-c4d). Three things to tell the user first:

- Newer machine families can be out of stock in a zone. Check that a machine can be created before committing to one.
- Packing more than about 100 sandboxes on a machine needs `TF_VAR_sandbox_max_pods_per_node` above the default 32.
- Memory is the limit to watch. A node that runs out evicts sandboxes, and they come back from their last snapshot.

## If something fails

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| `apply` fails on quota | Regional CPU or SSD quota | Lower `TF_VAR_max_sandbox_nodes`, or ask the user to raise the quota. |
| Node pool creation hangs, then reports `GCE_STOCKOUT` | No machines of that type in the zone | Try another region or machine type. GKE retries for about 35 minutes and blocks other cluster changes meanwhile. |
| Verifier fails with 403 on impersonation | `operator_member` is not the signed-in account, or IAM has not propagated | Check `gcloud auth list`, wait a minute, retry. |
| Verifier fails with "was not restored from its snapshot" | The region or GKE version lacks gVisor file snapshots, or the snapshot policy was not applied | Re-apply the manifests. Check `kubectl get podsnapshotpolicies -n sandboxes`. |
| Sandbox pod stays `Pending` | No room on the nodes and the pool is at its maximum | Raise `TF_VAR_max_sandbox_nodes` and apply again. |
| Wakes take tens of seconds | The sandbox holds very many files | Move caches and build output to `/tmp`. |

## Tear down

Ask first. This deletes every sandbox and snapshot.

```sh
kubectl get pods,podsnapshots -n sandboxes
terraform -chdir=infra output -raw manifests | kubectl delete --ignore-not-found -f -
TF_VAR_deletion_protection=false terraform -chdir=infra apply
TF_VAR_deletion_protection=false terraform -chdir=infra destroy
```

Deletion protection is on by default, so the first command turns it off before `destroy`. The snapshot bucket must be empty before Terraform can delete it. Keep the Terraform state until `destroy` finishes. Afterwards, confirm with `gcloud container clusters list --project "$TF_VAR_project_id"` that the cluster is gone.
