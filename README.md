# Element Install

Install Element Server Suite Community on a single Linux VPS and manage it by typing `element`. This independent installer automates Element's quick setup. The Matrix server, authentication service, web and admin clients, calling backend, and bundled PostgreSQL database come from Element's official Helm chart. [Upstream project and Community edition details](https://github.com/element-hq/ess-helm)

## Before you start

- Use a fresh, dedicated Debian 12+ or Ubuntu 22.04+ VPS with systemd, Python 3, curl, a public IP, and root or sudo access. The upstream minimum is 2 CPU cores and 2 GB RAM. Allow disk space for messages, media, container images, and the database. A VPS with more memory gives the stack room during installation and upgrades.
- Choose the domain that will appear in Matrix IDs, such as `@alice:example.org`. Changing it later requires rebuilding the homeserver. The installer serves Matrix discovery on that domain. If you already host a website there, choose a separate identity domain or follow Element's advanced reverse-proxy setup.
- Create public DNS records for **all six names** below. Each A record should point to the VPS, or use CNAMEs for service names. Publish AAAA records only if the VPS is reachable over IPv6. Use direct DNS for this setup. The wizard lets you replace each suggested hostname.
- In your provider and host firewalls, allow inbound **80/TCP** for certificate issuance, **443/TCP** for HTTPS, **30001/TCP** and **30002/UDP** for calls. Keep SSH reachable for administration. Restrict the K3s API and internal cluster ports to trusted traffic. Allow outbound HTTPS to fetch packages, charts, certificates and container images. [K3s networking requirements](https://docs.k3s.io/installation/requirements#networking)

| Example name | Used by |
| --- | --- |
| `example.org` | Matrix IDs and service discovery |
| `matrix.example.org` | Synapse |
| `account.example.org` | Matrix Authentication Service |
| `mrtc.example.org` | MatrixRTC calling |
| `chat.example.org` | Element Web |
| `admin.example.org` | Element Admin |

## Install

Run this in an interactive SSH session on the VPS. The command downloads the installer to a temporary file and runs it after curl succeeds. It requests sudo when needed.

```sh
(f=$(mktemp) && trap 'rm -f "$f"' EXIT && curl -fsSL https://raw.githubusercontent.com/Sownix21/Element-Install/main/element -o "$f" && /usr/bin/python3 -I "$f" install)
```

From a local checkout you can run `/usr/bin/python3 -I ./element install` instead.

1. Enter the identity domain, confirm the five service names, and supply a contact email for Let's Encrypt. Check the resolved IPs before confirming.
2. The installer sets up K3s, Traefik, Helm 3, cert-manager, and a production Let's Encrypt issuer. It looks up Element's latest stable GitHub release and installs the matching chart from Element's registry. K3s installs and enables its own `k3s.service` systemd unit for boot.
3. When certificates and HTTPS checks pass, the installer offers to create the first user. In the MAS wizard, choose **Set a password** and finish creating the account. You can run `element create-user` again later.
4. Open the printed Element Web URL, sign in, and try a message. For a calling deployment, test a call between clients on separate networks. [Matrix federation tester](https://federationtester.matrix.org/)

## Manage the server

Type **`element`** from any directory to open the numbered menu. Each menu item also works as a command.

| Command | Action |
| --- | --- |
| `element status` | Show the Helm release, workloads, volumes, ingress, and certificate status. |
| `element stop` | Save the replica counts for ESS Deployments and StatefulSets and scale them to zero. Data stays on the VPS. |
| `element start` | Restore saved counts and wait for the workloads to roll out. |
| `element restart` | Stop and start the ESS workloads. Expect downtime. |
| `element update` | Compare the installed chart to the latest official stable release, display the release notes link, and ask before upgrading. |
| `element logs` | Choose a pod and read its recent container logs. |
| `element diagnose` | Inspect K3s, disk, memory, pods, volume claims, certificate challenges, DNS, Helm history, and warning events. |
| `element create-user` | Open the official interactive MAS registration command. |
| `element verify` | Wait for certificates and test Matrix discovery, the client API, and the Element Web URL over HTTPS. |

The K3s service and certificate controller stay up when Element is stopped. Kubernetes retains the scaled workload settings across reboots. The operator command lives at `/usr/local/bin/element`. The setup choices and any saved replica counts live under `/etc/element-install/`. K3s holds the database, media volumes, and generated secrets.

## Recovery and updates

- **Interrupted setup:** Run `element diagnose`, correct the reported problem, then run `element install`. It reuses the saved domains and release. If the command was never installed, rerun the one-liner. For an interrupted start or stop, repeat the same command to complete scaling.
- **Certificate timeout:** Check every public A and AAAA record, both firewalls, and port 80 reachability from outside the VPS. Inspect `sudo k3s kubectl -n ess get challenges,orders,certificates`. After correcting DNS or routing, resume setup.
- **Pods pending or restarting:** Check disk and memory in `element diagnose` and inspect the affected pod with `sudo k3s kubectl -n ess describe pod POD_NAME`. For a crashed container's previous logs, use `sudo k3s kubectl -n ess logs POD_NAME -c CONTAINER_NAME --previous`.
- **Before an update:** Read the target release notes and take a recoverable backup of PostgreSQL, media, secrets, deployment markers, and installer configuration. Follow the upstream procedure to keep them consistent. A Helm revision alone cannot restore a migrated database. [Element backup and restore](https://github.com/element-hq/ess-helm/blob/main/docs/maintenance.md)
- **Failed upgrade:** Inspect `element diagnose` for the Helm revision and workload failures. A failed release can be retried with `element update`. An interrupted Helm operation marked pending may require manual recovery using Helm history and the matching release notes before a retry. [Upstream troubleshooting](https://github.com/element-hq/ess-helm/blob/main/docs/troubleshooting.md)
- **Installer and infrastructure updates:** `element update` upgrades the ESS chart and the components it packages. Rerun the one-liner to refresh the management script. K3s, Helm, cert-manager, and the OS have their own upgrade procedures.

For an existing cluster, external PostgreSQL, a shared reverse proxy, custom certificates, or public self-registration with SMTP, use the corresponding upstream setup instructions. [Element advanced configuration](https://github.com/element-hq/ess-helm/blob/main/docs/advanced.md)
