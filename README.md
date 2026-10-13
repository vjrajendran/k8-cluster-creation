# Kubernetes Cluster Automation Lab

This repository creates a three-node Kubernetes lab on AWS EC2 with Terraform, then configures it with Ansible and kubeadm.

| Node | Role |
| --- | --- |
| `master1` | Kubernetes control plane |
| `client1` | Worker |
| `client2` | Worker |

The cluster uses Ubuntu 24.04, containerd, Kubernetes packages from the v1.34 apt repository, and Flannel for pod networking. This is a learning environment, not a production cluster.

## How It Works

```text
Terraform creates the AWS resources and an SSH key
  -> Terraform connects to master1 and runs deploy.sh
  -> deploy.sh writes an Ansible inventory and checks SSH
  -> Ansible configures all nodes and installs Kubernetes
  -> kubeadm initializes master1; Flannel is installed
  -> kubeadm joins client1 and client2
  -> kubectl checks node readiness
```

`terraform/main.tf` provisions the infrastructure. `deploy.sh` supports both Terraform's non-interactive mode and the original interactive mode for manually created instances. `site.yml` and the roles in `roles/` perform node configuration.

## Prerequisites

- An AWS account and credentials with permission to describe the default VPC and Ubuntu AMIs, and create/manage EC2 instances, security groups, key pairs, and tags.
- Terraform CLI 1.5 or newer.
- AWS CLI, for configuring and checking credentials.
- An AWS default VPC with internet access in the selected region.

The default region is `us-east-1`. Terraform detects the current public IP and uses it for SSH and direct Kubernetes API access. The security group allows all traffic between cluster nodes; keep this project for trusted lab use.

## Create the Cluster

Configure AWS credentials locally. Do not put access keys in Terraform files or this repository:

```bash
aws configure --profile k8s-lab
aws sts get-caller-identity --profile k8s-lab
```

From the repository root, initialize and inspect Terraform:

```bash
cd terraform
export AWS_PROFILE=k8s-lab
terraform init
terraform validate
terraform plan
```

Review the plan for the expected resources: three EC2 instances, a security group, an EC2 key pair, and the bootstrap step. Apply it to create the cluster and start the Ansible deployment:

```bash
terraform apply
```

`run_deploy` defaults to `true`. Terraform generates `terraform/k8s-lab.pem` for SSH and uses the same key to configure worker access. Keep that private key and the Terraform state secure; do not send either to a developer.

When apply completes, Terraform prints a master SSH command. You can also retrieve it with:

```bash
terraform output ssh_master
```

Connect to `master1`, then verify the cluster:

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

All three nodes should eventually report `Ready`. The bootstrap waits for cloud-init and worker SSH, so first deployment can take several minutes. If bootstrap fails after instances are created, fix the reported cause and run `terraform plan`/`terraform apply` again; do not destroy the cluster just to retry the bootstrap.

### Terraform Settings

The example settings are in `terraform/terraform.tfvars.example`. `terraform/terraform.tfvars` is the active settings file in this checkout. It currently selects `main`, uses `t3.medium` for the master and workers, and targets `us-east-1`. Adjust instance sizes or `region` before applying if needed. AWS credentials should come from an AWS profile or environment, not `tfvars`.

Useful outputs:

```bash
terraform output
terraform output -raw master_public_ip
terraform output -json private_ips
```

## Give a Developer Access

Give the developer access to the Kubernetes API with a separate, namespace-scoped identity. Do not share `terraform/k8s-lab.pem`, `/home/ubuntu/.kube/config`, or `/etc/kubernetes/admin.conf`; those provide infrastructure or cluster-admin access.

This setup uses an SSH tunnel because kubeadm advertises the API server on the master's private IP. The API server remains restricted; the developer connects through SSH rather than exposing port 6443 to the internet.

### 1. Allow the Developer to SSH to `master1`

Ask the developer for their public SSH key (for example, the contents of `~/.ssh/id_ed25519.pub`) and current public IPv4 address. They send only the `.pub` file contents, never their private key.

Add the developer's address as an additional SSH source. Run from the repository root, replacing the example address with their real public IP:

```bash
terraform -chdir=terraform plan -var='additional_ssh_cidrs=["203.0.113.25/32"]'
terraform -chdir=terraform apply -var='additional_ssh_cidrs=["203.0.113.25/32"]'
```

`203.0.113.25/32` is an example; replace it with the developer's real public IPv4 address and `/32`. Keep your normal detected SSH address, and do not use `0.0.0.0/0`. Include the same `-var` on future Terraform plans/applies while this extra SSH access is needed, or Terraform may remove the extra rule.

Add their public key to the `ubuntu` account on the master. Run this from the repository root and replace the public-key file path:

```bash
ssh -i terraform/k8s-lab.pem \
  "ubuntu@$(terraform -chdir=terraform output -raw master_public_ip)" \
  'umask 077; cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' \
  < /path/to/developer_id_ed25519.pub
```

### 2. Create Namespace-Scoped Kubernetes Permissions

SSH to `master1` and run the following as `ubuntu`. This gives the developer permission to manage Deployments in the `developer` namespace and read workload status/logs. It does not grant access to Secrets or cluster-wide resources.

Although this Role grants no direct Secret API access, someone who can create workloads may be able to mount and expose Secrets from the same namespace. Do not put sensitive credentials in this namespace unless you also trust the developer with them; use a dedicated namespace and suitable admission policies for stronger isolation.

```bash
kubectl get namespace developer >/dev/null 2>&1 || kubectl create namespace developer
kubectl get serviceaccount developer -n developer >/dev/null 2>&1 || \
  kubectl create serviceaccount developer -n developer

cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer
  namespace: developer
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "services", "configmaps", "events"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["replicasets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developer-access
  namespace: developer
subjects:
- kind: ServiceAccount
  name: developer
  namespace: developer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: developer
EOF
```

### 3. Create and Securely Deliver a Kubeconfig

On `master1`, create a 24-hour service-account token and a kubeconfig that uses the local end of the SSH tunnel:

```bash
umask 077
token=$(kubectl create token developer -n developer --duration=24h)
ca_data=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
api_server=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
api_tls_server_name=${api_server#https://}
api_tls_server_name=${api_tls_server_name%:6443}

cat > "$HOME/developer.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: k8s-lab
  cluster:
    certificate-authority-data: ${ca_data}
    server: https://127.0.0.1:16443
    tls-server-name: ${api_tls_server_name}
contexts:
- name: developer@k8s-lab
  context:
    cluster: k8s-lab
    namespace: developer
    user: developer
current-context: developer@k8s-lab
users:
- name: developer
  user:
    token: ${token}
EOF

chmod 600 "$HOME/developer.kubeconfig"
unset token ca_data api_server api_tls_server_name
```

Copy the file from `master1` to your workstation, then deliver it through an approved secure channel. Treat it as a password; the token expires after 24 hours.

```bash
scp -i terraform/k8s-lab.pem \
  "ubuntu@$(terraform -chdir=terraform output -raw master_public_ip):/home/ubuntu/developer.kubeconfig" \
  ./developer.kubeconfig
```

### 4. Developer Connects

The developer needs `kubectl`, their own SSH private key matching the public key installed on `master1`, the kubeconfig, and the master's public/private IPs. Keep the SSH tunnel running in one terminal:

```bash
ssh -i ~/.ssh/id_ed25519 -N \
  -L 127.0.0.1:16443:<MASTER_PRIVATE_IP>:6443 \
  ubuntu@<MASTER_PUBLIC_IP>
```

In another terminal, protect and use the delivered kubeconfig:

```bash
mkdir -p ~/.kube
install -m 600 ./developer.kubeconfig ~/.kube/k8s-lab-developer.yaml
export KUBECONFIG="$HOME/.kube/k8s-lab-developer.yaml"
kubectl get pods -n developer
kubectl auth can-i create deployments -n developer
kubectl auth can-i get secrets -n developer
```

The last command should print `no`. The tunnel must remain open while `kubectl` is in use. Replace `<MASTER_PRIVATE_IP>` and `<MASTER_PUBLIC_IP>` with values shared by the cluster owner; get them with `terraform output -json private_ips` and `terraform output -raw master_public_ip`.

### Renew or Revoke Access

To renew access, repeat the token and kubeconfig creation step and securely deliver the replacement file. To remove Kubernetes permissions immediately, delete the RoleBinding on `master1`:

```bash
kubectl delete rolebinding developer-access -n developer
```

To invalidate the service-account token as well, delete its service account:

```bash
kubectl delete serviceaccount developer -n developer
```

Also remove the developer's SSH public key from `/home/ubuntu/.ssh/authorized_keys` and remove their IP from the `additional_ssh_cidrs` Terraform input when access is no longer needed.

## Manual Deployment Mode

Terraform is the recommended path. For three Ubuntu instances created separately, SSH to `master1`, clone this repository, and run:

```bash
sudo apt-get update
sudo apt-get install -y git ansible
git clone https://github.com/rvinodrajendran/k8-cluster-automation.git
cd k8-cluster-automation
chmod +x deploy.sh
./deploy.sh
```

The interactive script asks for the PEM key and the three private IPs. It uses the PEM only to install a generated SSH public key on the workers, then runs the same Ansible playbook. Keep the PEM out of the repository.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Terraform cannot connect to `master1` | Verify the AWS profile, public IP assignment, SSH source CIDR, and that cloud-init has completed. |
| Git reports that a branch cannot be found | Check `repo_branch`; the remote repository must contain that branch. The current setting is `main`. |
| Ansible reports `Permission denied (publickey)` | Check worker private IPs, `ubuntu` SSH access, and that the key was added to both workers. |
| `kubeadm join` times out | Check node-to-node security-group traffic and access from workers to `master1:6443`. |
| Developer SSH tunnel fails | Confirm their public IP is in `additional_ssh_cidrs`, the public key is installed on `master1`, and they use the matching private key. |
| Developer gets `Unauthorized` or `Forbidden` | Renew the 24-hour token if expired; check the service account, RoleBinding, namespace, and kubeconfig context. |
| Nodes remain `NotReady` | On `master1`, inspect `kubectl get pods -A`, Flannel pods, and `sudo systemctl status kubelet containerd`. |

Useful commands on `master1`:

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get pods -n kube-flannel -o wide
sudo systemctl status kubelet containerd
```

## Destroy the Lab

When you no longer need the cluster, destroy the resources managed by this Terraform state:

```bash
cd terraform
terraform destroy
```

Review the destroy plan before confirming. This removes the EC2 instances and security group and the locally generated key. Back up anything needed first.

## Repository Layout

```text
deploy.sh                         Interactive/non-interactive orchestrator
site.yml                          Three Ansible deployment phases
roles/common/                     OS and Kubernetes networking prerequisites
roles/containerd/                 Container runtime setup
roles/kubernetes/                 kubeadm, kubelet, kubectl installation
roles/control-plane/              kubeadm init and kubectl configuration
roles/worker/                     kubeadm join
terraform/main.tf                 AWS resources and bootstrap provisioner
terraform/variables.tf            Terraform inputs
terraform/outputs.tf              Connection details
```
