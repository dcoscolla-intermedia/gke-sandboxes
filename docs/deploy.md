# Deploy by hand

Use a test Google Cloud project with billing enabled. Terraform creates a zonal GKE Standard cluster, two autoscaling node pools, a private network with Cloud NAT, a snapshot bucket, and a controller service account. The manifests add a sweeper that puts idle sandboxes to sleep. Set `TF_VAR_name_suffix`, such as `-staging`, to deploy a second copy in the same project. Google bills for those resources. Allow for a 100 GB balanced disk per sandbox node and 50 GB per system node when checking regional SSD and E2 CPU quotas. The defaults peak at 8 vCPU: two `e2-standard-2` system nodes and one `e2-highmem-4` sandbox node.

Install Bun 1.4.4+, Terraform 1.15+, the Google Cloud CLI, kubectl, and gke-gcloud-auth-plugin. Configure Google Cloud CLI and application-default credentials with permission to create the resources, enable APIs, and grant IAM and Kubernetes permissions. The verifier impersonates the controller service account. Choose a region and GKE version that support gVisor file snapshots. [GKE Pod snapshots](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/pod-snapshots)

From the repo root, replace the project ID and email below, then run the commands in one shell.

```sh
export TF_VAR_project_id=your-disposable-project
export TF_VAR_operator_member=user:you@example.com
export TF_VAR_region=us-central1
export TF_VAR_zone=us-central1-a

bun install
terraform -chdir=infra init
terraform -chdir=infra apply
export KUBECONFIG="$(mktemp)"
gcloud container clusters get-credentials sandboxes --dns-endpoint \
  --project="$TF_VAR_project_id" --location="$TF_VAR_zone"
terraform -chdir=infra output -raw manifests | kubectl apply -f -
bun examples/verify.ts \
  --endpoint "$(terraform -chdir=infra output -raw endpoint)" \
  --controller "$(terraform -chdir=infra output -raw controller)"
```

The verifier creates a sandbox, writes a file, puts the sandbox to sleep, and waits for the original pod to disappear. It then wakes the sandbox, checks the file contents, and deletes the sandbox. Add `--concurrency 4 --rounds 3` to time twelve cycles, four at a time.

## Show a user what runs in a sandbox

`examples/preview` is a small proxy that lets a browser reach a web server inside a sandbox. Your backend signs a link for one sandbox and port after checking the user’s access. The link expires and cannot be changed to point elsewhere. Opening it keeps the sandbox awake while someone is looking. It does not wake a sleeping sandbox, since only your backend knows the options the sandbox runs with.

```sh
kubectl create configmap sandbox-preview -n sandbox-system --from-file=proxy.mjs=examples/preview/proxy.mjs
kubectl create secret generic sandbox-preview -n sandbox-system --from-literal=secret="$(openssl rand -hex 32)"
kubectl apply -f examples/preview/deployment.yaml
```

The proxy is reachable inside the cluster only, so put your own ingress and TLS in front of it. It serves HTTP under a path prefix and does not carry WebSockets. Copy `previewPath` from [proxy.mjs](../examples/preview/proxy.mjs) into your backend to sign links with the same secret.

## Deploy on C4D

The [C4D cost estimate and the build benchmark](comparison.md) use C4D machines with 4 vCPU / 8 GiB sandboxes. To deploy that, set these before `terraform apply`. C4D needs Hyperdisk, and a node needs room for more than the default 32 pods. Raise `TF_VAR_max_sandbox_nodes` and the system pool only in a project whose CPU quota allows it.

```sh
export TF_VAR_sandbox_machine_type=c4d-highmem-16
export TF_VAR_sandbox_node_disk_type=hyperdisk-balanced
export TF_VAR_sandbox_max_pods_per_node=256
```

Then give the client the matching sandbox size:

```ts
resources: {
  requests: { cpu: '100m', memory: '850Mi', 'ephemeral-storage': '4Gi' },
  limits: { cpu: '4', memory: '8Gi', 'ephemeral-storage': '20Gi' },
},
```

These requests fit 128 sandboxes on a `c4d-highmem-16`, which has about 116 GiB of memory left for pods. Memory is the limit to watch. A node that runs out evicts sandboxes, and they come back from their last snapshot. Measure what your agents use before lowering the memory request. C4D capacity varies by zone. When we tested, one of three Iowa zones had none.

## Clean up

Check for leftover pods and snapshots, then remove the test infrastructure. Keep the local Terraform state until teardown finishes. The cluster has deletion protection on by default, so turn it off with an apply before `destroy`. The example disables bucket soft delete and the bucket must be empty before Terraform can delete it.

```sh
kubectl get pods,podsnapshots -n sandboxes
terraform -chdir=infra output -raw manifests | kubectl delete --ignore-not-found -f -
TF_VAR_deletion_protection=false terraform -chdir=infra apply
TF_VAR_deletion_protection=false terraform -chdir=infra destroy
```
