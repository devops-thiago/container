# Container cluster

Kubernetes is an open-source orchestration platform for automating deployment, scaling, and management of containerized workloads across clusters of machines. With `container`, you can run local Kubernetes clusters for development and testing.

> [!WARNING]
> `container cluster create --shared-image-store` lets cluster nodes use your local image store, so pods can run images you build or pull with `container` without a registry. Sharing is off by default. With sharing on:
>
> - Anything with root on a node, including privileged pods and pods with a `hostPath` mount, can read every image in your local image store, including private images you pulled with your registry credentials.
> - A local image is used before a registry image with the same name, for every pull policy, and without the pod's pull secrets.
> - Nodes cannot add, change, or delete images in your local image store.
>
> Without `--shared-image-store`, nodes pull every image from a registry, as in a standard Kubernetes cluster.

## Why Kubernetes on container

Running Kubernetes locally with `container` gives you a streamlined workflow to build and test workloads before deploying to production:

- **Fast iteration.** Create and destroy clusters in seconds. Test your deployments locally before pushing to a remote cluster.
- **Multiple cluster versions.** Run different Kubernetes versions side-by-side without conflicts. Test compatibility across versions with ease.
- **Load your own images.** Images built with `container build` can be loaded directly into your cluster. Build once, run anywhere — local Kubernetes or production.
- **Lightweight VMs.** Clusters run as lightweight VMs on your Mac.
- **No special setup.** Uses standard Kubernetes tooling (`kubectl`, kubeconfig) — the same CLI and configuration files you use with production clusters.

## Quickstart

```bash
# Create a cluster
container cluster create

# Verify the cluster is running
container cluster list

# Interact with the cluster using kubectl
kubectl cluster-info
kubectl get nodes

# Clean up when done
container cluster delete
```

The cluster is automatically added to your `~/.kube/config`, so standard Kubernetes tools just work.

## Working with clusters

### Create and list clusters

Create a cluster with `container cluster create`. By default, it creates a cluster named `cluster-dev`:

```bash
container cluster create
```

You can create multiple named clusters:

```bash
container cluster create --name staging
container cluster create --name testing
```

List all clusters and their status:

```bash
container cluster list
```

Add `--nodes` to show one row per node instead of one row per cluster. Clusters created with an earlier version are not listed.

### Cluster lifecycle

Create a cluster, use it with kubectl, and delete it when finished:

```bash
# Create a cluster
container cluster create --name my-cluster

# Use the cluster with kubectl
kubectl --context my-cluster get pods

# Delete the cluster when finished
container cluster delete --name my-cluster
```

### Cluster nodes and container commands

Each cluster node runs as a container, but `container cluster` manages those containers for you. To keep them from being changed by accident, the container lifecycle commands treat cluster nodes differently:

- `container list` hides cluster nodes, even with `--all`. Use `container cluster list` to see them.
- If you name a cluster node, `container start`, `container stop`, `container kill`, and `container delete` report it as not found, as they would for a container that doesn't exist. Other containers named in the same command are still processed.

Commands that don't change a node's lifecycle, such as `container inspect`, `container logs`, `container exec`, `container stats`, and `container clean`, work on a cluster node you name. Use `container cluster delete` to remove a cluster and its nodes.
Stop a cluster to free its resources without losing it, and start it again later:

```bash
container cluster stop --name my-cluster
container cluster start --name my-cluster
```

`container k8s` remains a compatibility alias, so `container k8s start --name my-cluster` does the same. Without `--name`, the old spelling targets `k8s-dev` and the new spelling targets `cluster-dev`. Existing scripts keep their original target even when both clusters exist; neither spelling substitutes the other default if its own is missing. The alias remains supported. `kubectl` still uses the selected context when no name is supplied.

Clusters created with `--cni NONE` retain that choice across stop/start. Start waits for the API server and every cluster node to register; it does not claim that nodes are Ready or that CoreDNS is Available. Other clusters keep the full readiness checks.

For an older no-CNI cluster without a saved choice, select it explicitly:

```bash
container cluster start --name my-cluster --readiness registered
```

After installing a CNI, use `--readiness ready` to restore full node and CoreDNS checks. The choice is saved with the control plane's data, including when a readiness check fails. Without saved metadata or an explicit choice, start requires full readiness. A NotReady node never selects the weaker policy automatically.

This option does not adopt legacy nodes or change their permissions. When adoption is required, `--adopt-legacy` is a separate explicit choice. Invalid saved metadata produces an error; either readiness option can replace it with the user's chosen policy.

### Customize resources

Allocate CPU and memory based on your needs:

```bash
# Create a cluster with 4 CPUs and 8GB memory
container cluster create --name high-resource --cpus 4 --memory 8g
```

By default, clusters use 1/4 of your host's CPUs (minimum 2) and 1/4 of your host's memory (minimum 2GB).

### Multi-node clusters

By default, `container cluster create` creates a single node that acts as both control plane and worker. Use `--workers` to add dedicated worker nodes instead:

```bash
# Create a cluster with a control plane and 3 worker nodes
container cluster create --name my-cluster --workers 3
```

When `--workers` is greater than `0`, the control-plane node is tainted so pods only schedule onto worker nodes, matching typical multi-node cluster behavior. Worker nodes share the control plane's `--node-image` and are named `<cluster-name>-worker-<n>`.

`--cpus` and `--memory` size the control-plane node, or the single node if no workers are specified.

To size workers, pass a group of workers with `--workers count=<n>,cpus=<n>,memory=<size>`. A group's `count` defaults to `1`. If you leave out `cpus` or `memory`, the workers get the single-node defaults: 1/4 of your host's CPUs and memory, minimum 2 CPUs and 2GB. Repeat the option to create groups of differently sized workers:

```bash
# Control plane with 2 CPUs and 4GB, 2 workers with 4 CPUs and 8GB, plus 1 smaller worker
container cluster create --name my-cluster --cpus 2 --memory 4g \
  --workers count=2,cpus=4,memory=8g \
  --workers count=1,cpus=2,memory=4g
```

### Access clusters with kubectl

Once a cluster is created, `kubectl` works normally:

```bash
# Use your created cluster
kubectl --context cluster-dev get pods
kubectl --context cluster-dev describe node

# Switch between clusters
kubectl config use-context staging
```

## Use container images in your cluster

A cluster created with `--shared-image-store` can pull the images in your local image store. Build or pull an image with `container`, and reference it by name in a pod spec:

```bash
container cluster create --shared-image-store
container build -t my-app:dev .
kubectl run my-app --image=my-app:dev
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-app
spec:
  containers:
  - name: app
    image: my-app:dev
  restartPolicy: Never
```

If the local image store does not have an image, or has none of its content for the node's platform, the node pulls it from its registry as usual.

The first time a node uses a local image, it copies the image's content for its platform from your local image store, the same way it stores an image it pulls from a registry.

An image name without a registry, such as `my-app:dev`, is looked up in the local image store the same way `container` resolves it, using your default registry domain (`registry.domain`). Inside the cluster, Kubernetes shows such an image under its docker.io name, for example `docker.io/library/my-app:dev`.

> [!NOTE]
> - Every pull policy works, including `imagePullPolicy: Never`.
> - Sharing is set when the cluster is created. To change it, delete the cluster and create it again.
> - After rebuilding a tag, use `imagePullPolicy: Always` or a new tag so the node picks up the new image. With `IfNotPresent`, a node keeps the image it already has.

### Load an image into a cluster

A cluster created without `--shared-image-store` can still run a local image: load it into the cluster first. The image is placed in the `k8s.io` namespace of every node, the control plane and each worker, making it available to pods on any node:

```bash
container build -t my-app:latest .

# Load the image into every node of the cluster
container cluster load-image my-app:latest

# Load the image into specific nodes only
container cluster load-image --node cluster-dev-worker-1 --node cluster-dev-worker-2 my-app:latest
```

Reference a loaded image with `imagePullPolicy: Never` or `IfNotPresent`, so the node uses its copy rather than pulling from a registry.

## Kubernetes node image

By default, clusters use `kindest/node:v1.35.5`, a Kubernetes-in-Docker image optimized for local development. You can use a different node image when creating a cluster:

```bash
container cluster create --node-image docker.io/kindest/node:v1.34.11
```

## Custom CNI

By default, clusters install the bundled kindnet CNI for pod networking. Use `--cni` to apply a different CNI manifest instead:

```bash
container cluster create --name my-cluster --cni ./my-cni.yaml
```

The manifest must be a plain Kubernetes YAML file (the same shape `kubectl apply -f` expects), not a Helm chart.

### Example: Cilium

Cilium is distributed as a Helm chart, so render a plain manifest from it first:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm template cilium cilium/cilium --version 1.20.1 --namespace kube-system --set ipam.mode=kubernetes > cilium.yaml
```

`--set ipam.mode=kubernetes` avoids a CIDR conflict: the chart's default (`cluster-pool`, `10.0.0.0/8`) overlaps kubeadm's pod subnet and service CIDR on these clusters.

Then create the cluster with that manifest:

```bash
container cluster create --name cilium-demo --cni ./cilium.yaml
```

Verify Cilium came up:

```bash
kubectl --context cilium-demo get pods -n kube-system
kubectl --context cilium-demo get nodes -o wide
```

## Cluster cleanup

Remove a cluster and its data:

```bash
container cluster delete --name my-cluster
```

To have a cluster automatically remove itself when stopped, create it with `--rm`:

```bash
container cluster create --name temp-cluster --rm
```

The node containers are removed when they stop, but the cluster's stored configuration remains, so the cluster shows as `stopped` in `container cluster list` until you run `container cluster delete --name temp-cluster` or create a cluster with the same name again (which clears the stale configuration).

### Recovering a stopped cluster

If a cluster's nodes stop (for example, after `container stop` or a restart of the engine), start the cluster again:

```bash
container cluster start --name my-cluster
```

## Common workflows

### Test a deployment locally before production

```bash
# Create a test cluster
container cluster create --name test

# Build your image locally; the cluster pulls it by name
container build -t my-service:v1.0 .

# Deploy to the test cluster
kubectl --context test apply -f deployment.yaml

# Verify everything works
kubectl --context test logs deployment/my-service

# Clean up when done
container cluster delete --name test
```

### One cluster per feature branch

```bash
# Create isolated clusters for concurrent development
container cluster create --name feature-auth
container cluster create --name feature-payments

# Work on each feature in isolation, test against its own cluster
```

## See also

- [Command reference](./command-reference.md#container-cluster-management) — full details of all `container cluster` subcommands
- [Container machines](./container-machine.md) — persistent Linux environments for general-purpose development

## Adopting nodes created by older versions

Older node configurations did not record their need for writable `/sys`. Labels alone no
longer enable it, because ordinary containers can carry the same labels. If starting an old
cluster reports that adoption is required, stop the cluster and explicitly adopt its nodes:

```sh
container cluster stop --name my-cluster
container cluster start --name my-cluster --adopt-legacy
```

This records the permission on each existing node without deleting or recreating it. Each
update checks the node's creation identity, so a replacement with the same name is refused.
Once adopted, later starts do not need the flag. New clusters already record the permission.

An old builder may need the same explicit authorization: stop it, then run
`container builder start --adopt-legacy`. Normal builder configuration changes can still
cause its existing recreation policy to apply.
