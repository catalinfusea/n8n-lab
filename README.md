# n8n standalone lab VM (Vagrant + VMware Workstation)

One PowerShell script that builds a throwaway Ubuntu 24.04 VM running
[n8n](https://n8n.io) (Community Edition, pinned 2.x) + PostgreSQL 16 in Docker,
on Windows 11 with VMware Workstation. Romanian version: [README.ro.md](README.ro.md).

> Status: personal lab project. Syntax of the generated Vagrantfile, bash
> provisioners, compose file and PowerShell was validated; the full
> `vagrant up` flow was run on my host. Anything marked "untested" below was not.

## What it creates

- VM `bento/ubuntu-24.04`, 2 vCPU / 4 GB RAM (`vagrant-vmware-desktop` provider), on VMware NAT (VMnet8)
- Docker CE + n8n (pinned, **not** `latest`) + PostgreSQL 16 under `/opt/n8n` in the guest
- n8n bound to guest `127.0.0.1:5678` only; reached through an SSH tunnel
- Generated next to the script: `Vagrantfile`, `docker-compose.yml`, `.env`, `Start-n8n-Tunnel.ps1`

## Hardening choices

- `.env` is generated once and never overwritten (Postgres password and
  `N8N_ENCRYPTION_KEY` must stay stable); ACL restricted to the current user
- No Portainer / no `docker.sock` mount; no custom NAT port forwards
- `/vagrant` synced folder disabled (guest cannot write to the host folder)
- Guest SSH: key-only
- n8n telemetry and version checks disabled
- `vmnetnat.conf` is backed up before `vagrant up` and diffed afterwards

## Requirements

Vagrant, `vagrant-vmware-desktop` plugin, Vagrant VMware Utility service running,
VMware Workstation. Optional: Ollama on the host listening on `127.0.0.1:11434`.

## Usage (on the Windows host)

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-n8n-Lab.ps1
cd "<project folder>\n8n"; .\Start-n8n-Tunnel.ps1   # keep open, Ctrl+C closes
```

Then open http://localhost:5678. Set `$ProjectPath` and `$N8nVersion` at the top of the script first.

Local Ollama from n8n (reverse SSH tunnel, **untested end to end**): use the
*Ollama Chat Model* node with base URL `http://host.docker.internal:11434`
(no `/v1`); the n8n Assistant (OpenAI-compatible endpoint) needs `/v1`.

## Known caveats

- `vagrant up` restarts the VMware NAT service: other VMs on VMnet8 lose connectivity briefly and
  existing NAT forwards in `vmnetnat.conf` can be rewritten. Run it with other VMs stopped.
- The VM shares VMnet8 with anything else on VMware NAT. For isolation, move it behind a firewall segment.
- n8n 3.0 (beta since 2026-10-27) has breaking changes and a one-way upgrade; the version is pinned on purpose.
- The n8n Community license allows internal use only: see the [license FAQ](https://docs.n8n.io/n8n-community-license/community-license/license-faq).

## License

Scripts: add a license of your choice before publishing. n8n itself is under its own Sustainable Use License.
