---
apply: always
---

# redmilab — instructions

## Purpose

Personal homelab for learning and self-hosting: GitOps, k3s, Ansible,
Linux, and networking. Everything in this repo exists to manage that
homelab declaratively — no manual snowflake configuration.

Target end state:

- k3s cluster across the phones with an **external datastore** (not
  embedded etcd/sqlite), so the control plane is decoupled from any
  single node.
- Full GitOps on the cluster with **Flux CD**; cluster secrets managed
  by **External Secrets Operator (ESO) backed by Infisical**.
- **Tailscale Kubernetes operator** hosted in the cluster.

## Hardware

| Host            | Device                                                                                | OS / userland                                                             |
|-----------------|---------------------------------------------------------------------------------------|---------------------------------------------------------------------------|
| `xiaomi-whyred` | Redmi Note 5 (Snapdragon 636, sdm636), 4 GB RAM                                       | postmarketOS (Alpine-based, OpenRC)                                       |
| `xiaomi-mido`   | Redmi Note 4 Snapdragon (Snapdragon 625 / MSM8953, 8× Cortex-A53 @ 2.0 GHz), 4 GB RAM | postmarketOS (Alpine-based, OpenRC)                                       |
| `netbook`       | ASUS Eee PC (32-bit Intel Atom, 2 GB RAM, 256 GB SSD)                                 | Alpine Linux 32-bit (x86), OpenRC; escalates via `community.general.doas` |

- The phones are the k3s nodes (`k3s_nodes` group). `whyred` additionally
  gets the `cpuidle-fix` role; do not apply whyred-specific workarounds
  to `mido`.
- The netbook is in the `storage` group and hosts shared/stateful bits
  (e.g. the planned external k3s datastore). **It is a single point of
  failure for the setup** — acknowledge this in any design suggestion;
  removing the SPOF is out of scope unless asked.
- The netbook can never be a k3s node: k3s ships `x86_64`/`armhf`/`arm64`
  binaries only, no 32-bit x86. Cluster nodes are the two phones
  (both 64-bit ARM); the netbook is storage/datastore only.
- Phones stay plugged in; battery longevity is managed by
  `ansible/roles/cronjobs/files/battery-cycle.sh`, which cycles charging
  between ~40–60 %. Do not "fix" charging behavior outside that script.
- Known hardware quirk, do not regress: whyred idles hot (~700 mA) due
  to a firmware/cpuidle defect; `ansible/roles/cpuidle-fix` disables the
  rejected idle states at boot and on apply. Full analysis in
  `docs/whyred-power-investigation.md`.

## Network (Tailscale-first)

- All hosts are on a Tailscale tailnet: `*.tailba091b.ts.net`,
  CGNAT range `100.64.0.0/10` (see `firewall` role defaults).
- There is no public inbound and no static IPs — every integration
  (CI, SSH, future k8s API access) goes over Tailscale.
- `firewall` role opens TCP 6443 (k8s API) to the pod network
  (`10.42.0.0/16`), LAN (`192.168.1.0/24`), and tailnet only.
- Ansible connects as `admin` over Tailscale hostnames
  (`ansible/inventory.yml`); netbook escalates via
  `community.general.doas`.

## Change management: CI owns the machines

- **Do not change machine configuration over ad-hoc SSH.** All writes
  go through the `Deploy` workflow (merge to `main`).
- Read-only SSH investigation (`cat`, `dmesg`, sysfs sampling) is
  acceptable for diagnosis, as in `docs/whyred-power-investigation.md`.
  The repo contributor is the Tailscale admin, is connected to the
  tailnet, and can reach every machine over Tailscale SSH — so
  read-only remote inspection is always available when needed.
- Local `ansible-playbook` runs from the dev machine are not allowed at
  all - validate via CI, not local applies.

## Money: zero budget

- No spending on software or hardware. No paid SaaS tiers, no new
  devices, no "just buy a…". Design within the 2 phones + netbook +
  free-tier services already in use.

## Secrets

- **Infisical is the only source of truth for secrets.** Project
  `redmilab-k4s-u`, env `prod`, fetched at deploy time via OIDC
  (`Infisical/secrets-action` + `id-token: write`; nothing to rotate).
- Never commit secrets to git. Never use local `.env` files for real
  credentials (`.gitignore` already excludes `*.env`, `*.pem`,
  `*.key`, `secret.yaml`).
- Avoid creating new secrets at all — prefer flows that need no stored
   credential (OIDC, Tailscale ACL tags like `tag:deploy`).
- The Tailscale OAuth client ID and Infisical identity ID in
  `.github/workflows/deploy.yml` are **public identifiers, not
  secrets** (auth comes from OIDC). They are allowlisted in
  `.gitleaks.toml` by exact value — do not "fix" by deleting them, and
  do not broaden that allowlist to whole files.
- gitleaks scans full history on PRs; new true positives must be
  rotated, not allowlisted.

## Ansible layout (`ansible/`)

- Ansible's job here is twofold: configure the machines (packages,
  services, firewall, cronjobs, device-specific fixes) and bootstrap
  the entire k3s cluster. `playbook.yml` composes one role per concern.
- `pip install ansible` (community package) already bundles
  `community.general`; there is intentionally no `requirements.yml`.
- `ansible-lint` runs on every PR (see CI below) and is the quality
  gate: new roles/tasks must be lint-clean. If the linter flags new
  code, fix the code, not the config — no `skip_list` without asking.
- Alpine Postgres packaging quirk (verified Oct 2026): `setup` moves
  configs to `/etc/postgresql/` (symlink to `postgresql<ver>/`) and
  symlinks them back into the data dir. `lineinfile` follows those
  links, but `template`/`copy` *replace* them with regular files the
  server never reads — so manage Postgres configs at their `/etc`
  paths directly, never via the data dir.

## CI/CD (`.github/workflows/`)

- `ci.yml` (on PRs):
  - `lint` job: `ansible-lint playbook.yml` from `ansible/`.
  - `secrets` job: `gitleaks/gitleaks-action@v3`.
- `deploy.yml` (on push to `main`): Tailscale connect
  → Infisical OIDC secret fetch → `ansible-playbook playbook.yml`.
- Conventions: Keep CI jobs read-only (no Tailscale, no secrets in
  `ci.yml`); only `deploy.yml` touches real infrastructure.

## Code preferences

- Ansible: FQCN everywhere (`ansible.builtin.*`), `---` document start
  on every YAML file, capitalized task and handler names, role-prefixed
  variables (`firewall_*`). Prefer distro-agnostic modules over
  distro-specific ones — e.g. `ansible.builtin.package` over
  `community.general.apk` — but only when the task runs exactly the
  same with zero extra `when:` branches or per-distro variables. If
  agnosticism would need conditionals or variable plumbing, use the
  direct distro-specific module instead; all hosts run Alpine-family
  today, so simplicity wins over hypothetical portability.
- Tasks must be idempotent and lint-clean (`changed_when`, `creates:`,
  no bare `shell` pipes). If `ansible-lint` flags new code, fix the
  code, not the config — no `skip_list` without asking.
- Workflows: minimal steps, least-privilege `permissions`.
  Prefer premade/official pieces over raw bash in both workflows and
  Ansible (published actions, real Ansible modules); raw `run:` /
  `shell` only when no module or action exists for the job.
- Docs: investigation notes live in `docs/`; record method, raw
  numbers, and verdicts.

## Evidence over assumption

- Base technical claims on documentation first (official upstream docs), online forums and community
  sources second. Do not present guesses as facts.
- If you must assume something (e.g. an undocumented OS detail or a
  default you couldn't verify), say so explicitly and mark what would
  confirm or refute it.

