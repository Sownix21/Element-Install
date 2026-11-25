# Element Install

[راهنمای فارسی](README.fa.md)

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
2. The installer pins a release from this project's GitHub mirror, verifies each downloaded file against its SHA-256 manifest, and loads the bundled images directly into K3s. The bundle includes K3s, its system images, Helm 3, the ESS and cert-manager charts, and their images. K3s enables its own systemd service at boot.
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
| `element update` | Compare the installed chart to the latest mirrored ESS release and ask before upgrading with your current Helm settings. |
| `element logs` | Choose a pod and read its recent container logs. |
| `element diagnose` | Inspect K3s, disk, memory, pods, certificates, DNS and events. In an interactive terminal, it offers to start inactive K3s or reload missing ESS or cert-manager images when a pod reports a pull failure. |
| `element create-user` | Open the official interactive MAS registration command. |
| `element verify` | Wait for certificates and test Matrix discovery, the client API, and the Element Web URL over HTTPS. |
| `element registration` | Enable or disable public password signup. Enabling requires verified email. Use working MAS SMTP settings or enter your relay details. |
| `element upload-limit` | Set the Synapse upload limit in MiB using the installed chart. An external proxy may impose its own limit. |
| `element users` | List local MAS accounts with lock and deactivation timestamps from the bundled PostgreSQL database. |
| `element deactivate-user` | Enter and confirm a local username to deactivate it through MAS. This can remove the account from rooms. |
| `element reset-password` | Change a local password using a MAS admin token. The token and password are entered at hidden prompts. |
| `element backup` | Pause workloads and archive the database, media, settings and secrets. The command restores the previous running state after the copy. |
| `element uninstall` | Wipe the entire dedicated K3s cluster, installer state, cache, and local Element backups. Type the displayed domain-specific phrase to proceed. |

The K3s service and certificate controller stay up when Element is stopped. Kubernetes retains the scaled workload settings across reboots. The operator command lives at `/usr/local/bin/element`. The setup choices and any saved replica counts live under `/etc/element-install/`. K3s holds the database, media volumes, and generated secrets.

For password resets, use an administrator account to obtain a short-lived token with the `urn:mas:admin` scope through the documented device login flow. Paste the access token when prompted. Users need their own Matrix recovery key or a verified device to recover encrypted history. [MAS access tokens](https://element-hq.github.io/matrix-authentication-service/topics/access-token.html)

After enabling registration, try signing up with a new address and check that the verification email arrives. SMTP credentials are stored in a Kubernetes Secret. Disabling registration closes new password signups and existing accounts can still sign in.

## GitHub mirror

GitHub Actions checks upstream daily at **03:17 UTC**. The mirror packages the latest commit on Element's `main` that touched `charts/matrix-stack`, including changes between stable releases. The manifest records the source commit. Changes to that revision, dependency versions, selected image digests, available platforms, cert-manager chart content or the bundle builder trigger a fresh bundle. Use **Actions → Build install bundle → Run workflow** to check immediately. [Bundle releases](https://github.com/Sownix21/Element-Install/releases)

Each release lists its supported Linux architectures in `manifest.json` under `architectures`. The runner matches published K3s binaries and air-gap archives to Helm binaries, then checks every required container image for each platform. A missing platform is explained in the build log. The VPS downloads its own architecture and shared charts. Existing servers opt in to the main snapshot using `element update`.

The VPS needs access to GitHub raw content, releases and their asset CDN, plus Let's Encrypt and the distribution mirror for any missing OS packages. Existing installations upgrade on demand with `element update`. Rerun the one-liner to get a newer management console.

## Backups and recovery

`element backup` writes a root-only, **unencrypted** archive under `/var/backups/element-install/`. Allow space there for the compressed database and media. Messages and calls pause during the copy. If the host loses power during backup, use `element start` to resume a previously running stack. Copy the archive off the VPS before uninstalling.

This is a physical backup for the bundled PostgreSQL and K3s local storage. It includes all ESS PVC directories under `volumes/<claim>`, plus installer config, actual Helm values, replica counts, secrets and config maps. Recovery is manual. On an isolated compatible node use the same domain, chart and PostgreSQL major version. Recreate the required generated secrets, SMTP secrets and deployment markers from the exports, then provision matching claims. With all ESS workloads stopped, restore each archived volume into its corresponding claim directory with original numeric ownership and permissions. Reapply the saved chart values, start the recorded workloads and test sign-in, media and calls before switching DNS. The archive contains account and encryption secrets. Keep access to it restricted. [Element maintenance guide](https://github.com/element-hq/ess-helm/blob/main/docs/maintenance.md)

## Recovery and updates

- **Interrupted setup:** Run `element diagnose`, correct the reported problem, then run `element install`. It reuses the saved domains and release. If the command was never installed, rerun the one-liner. For an interrupted start or stop, repeat the same command to complete scaling.
- **Certificate timeout:** Check every public A and AAAA record, both firewalls, and port 80 reachability from outside the VPS. Inspect `sudo k3s kubectl -n ess get challenges,orders,certificates`. After correcting DNS or routing, resume setup.
- **Pods pending or restarting:** Check disk and memory in `element diagnose` and inspect the affected pod with `sudo k3s kubectl -n ess describe pod POD_NAME`. For a crashed container's previous logs, use `sudo k3s kubectl -n ess logs POD_NAME -c CONTAINER_NAME --previous`.
- **Before an update:** Read the target release notes and take a recoverable backup of PostgreSQL, media, secrets, deployment markers, and installer configuration. Follow the upstream procedure to keep them consistent. A Helm revision alone cannot restore a migrated database. [Element backup and restore](https://github.com/element-hq/ess-helm/blob/main/docs/maintenance.md)
- **Failed upgrade:** Inspect `element diagnose` for the Helm revision and workload failures. A failed release can be retried with `element update`. An interrupted Helm operation marked pending may require manual recovery using Helm history and the matching release notes before a retry. [Upstream troubleshooting](https://github.com/element-hq/ess-helm/blob/main/docs/troubleshooting.md)
- **Installer and infrastructure updates:** `element update` upgrades the ESS chart and the components it packages. Rerun the one-liner to refresh the management script. K3s, Helm, cert-manager, and the OS have their own upgrade procedures.

For an existing cluster, external PostgreSQL, a shared reverse proxy or custom certificates, use the corresponding upstream setup instructions. [Element advanced configuration](https://github.com/element-hq/ess-helm/blob/main/docs/advanced.md)
