# pve — Proxmox container helpers

Bash functions for managing Debian LXC containers (run on the Proxmox host).
Source the files to load the functions:

```bash
source ./container_functions.sh
source ./docker_functions.sh     # auto-sources container_functions.sh
source ./redeploy_functions.sh   # auto-sources the other two
```

All functions accept a **CTID or a container name** (resolved via `pct list`).

## container_functions.sh

| Function | What it does |
| --- | --- |
| `update_debian <ct>` | `apt update && upgrade -y && autoremove -y` inside the container. |
| `update_template [ct]` | Update a template (default CTID 999): clears the `template:` flag, starts, updates, stops, re-sets the flag. Toggles the flag in `/etc/pve/lxc/<id>.conf` — it does **not** run `pct template` (the disk is already a basevol). Root + host only. |

## docker_functions.sh

These target the "docker host" pattern: docker running, with a compose file
that should live at **`/opt/<project>/docker-compose.yml`** with project-local
bind mounts alongside it. Containers without docker are reported **n/a** and
never touched.

Compose files are discovered from **running containers' labels**
(`com.docker.compose.project.*`), so multiple projects per host are handled and
the real on-disk location (`/opt`, `~`, `/opt/app`, …) doesn't need guessing.
If nothing is running, it falls back to a filesystem search.

### Eligibility: two PVE tags

The bulk helpers (`validate_all_docker`, `convert_all_docker`) decide what to
act on using two tags:

| Tag | Role | Default | Override |
| --- | --- | --- | --- |
| `docker` | **allowlist** — only CTs with this tag are considered | `docker` | `DOCKER_TAG` |
| `noauto` | **denylist** — CTs with this tag are never touched | `noauto` | `DOCKER_PROTECT_TAG` |

> **eligible = tagged `docker`  AND NOT tagged `noauto`**

```bash
pct set 118 --tags docker          # opt CT 118 in
pct set 118 --tags docker;noauto   # in the fleet, but temporarily protected
```

`pct set --tags` **replaces** the whole tag list, so always pass every tag you
want the CT to keep.

Notes:

- **Single-CT calls** (`convert_to_standard 118`, `validate_docker_pattern 118`)
  ignore the `docker` allowlist — calling them by ID is itself opt-in — but
  `convert_to_standard` still **refuses** a `noauto` container.
- The `docker` tag is just an eligibility flag; the functions still verify
  docker is actually installed/running at runtime (`ct_has_docker`).

| Function | What it does | Returns |
| --- | --- | --- |
| `ct_has_docker <ct>` | True if docker is installed and the daemon is up. | 0/1 |
| `find_compose <ct>` | Print absolute path(s) of compose file(s), one per line. | 0 found / 1 none |
| `validate_docker_pattern <ct>` | Verdict on conformance to the standard layout. | 0 conformant / 1 needs work / 2 n/a |
| `validate_all_docker` | Run the validator across every container (skips protected). | — |
| `convert_to_standard <ct> [--apply]` | Migrate each project to `/opt/<project>/`. **Dry-run by default**; refuses protected containers. | 0/1/2 |
| `convert_all_docker [--apply]` | Run the converter across every eligible container (docker + not protected). **Dry-run by default**. | — |
| `compose_up_all <ct>` | `docker compose up -d` for every `/opt/<app>/docker-compose.yml`. | 0/2 |

## redeploy_functions.sh — cattle-style rebuilds

Destroy a container and recreate a fresh one from a template, as a **drop-in
replacement**: same CTID, same MAC/VLAN/bridge/IP, same bind mounts, same
idmap, same `/opt` payload — but on a fresh OS/template. The point is to stop
hand-`dist-upgrade`ing pets and instead reprovision from a known-good template.

What's preserved (read off the old config):

- **Identity:** CTID (reused), `net*` lines verbatim (MAC, VLAN `tag`, bridge, IP/gw), hostname.
- **Resources & flags:** cores, memory, swap, onboot, startup, arch, features, tags.
- **Mounts:** bind mounts (host paths, e.g. ZFS media) re-attached. **Storage-backed
  volumes are detected and the redeploy aborts** rather than let `pct destroy` wipe them.
- **idmap / raw `lxc.*`** lines.
- **`/opt`** (on rootfs): tar'd off the old CT and restored into the clone.

What's NOT carried: docker images and named volumes (images re-pulled on
`compose up`; the pattern keeps real data in bind mounts under `/opt`).

### Preserving base-system changes

Things outside `/opt` — a `Caddyfile`, `/etc/crontab`, a custom systemd unit —
are reset to the template's version on redeploy unless you list them in a
**preserve manifest**: `/etc/pve/redeploy/<ctid>.preserve`, one absolute path
per line (`#` comments allowed). redeploy tars those paths off the old CT,
restores them into the clone, then reboots so systemd/caddy/cron pick them up.

`ct_changed_files <ct>` helps you build it — it shows everything that has
drifted from a stock Debian + template:

- modified package files via `dpkg -V` (conffiles like `Caddyfile`, `/etc/crontab`);
- unpackaged files in config dirs (custom units, `cron.d`, `/usr/local` scripts, user crontabs).

```bash
ct_changed_files 118                       # see what drifted
$EDITOR /etc/pve/redeploy/118.preserve     # list the paths worth keeping
```

> Tip: the cleanest fix is to *eliminate* the manifest — fold reverse proxies
> into each stack's `docker-compose.yml` (a caddy service per project) so almost
> nothing lives on the base system. The manifest is the escape hatch for the rest.

| Function | What it does |
| --- | --- |
| `redeploy_lxc <ct> [template] [--apply]` | The rebuild. **Dry-run by default** (prints exactly what it will carry over, including preserved paths). Template defaults to `$REDEPLOY_TEMPLATE` (999). Refuses protected (`noauto`) CTs and unprivileged-mismatched templates. |
| `rollback_lxc <ct> [backup]` | Restore from the vzdump taken during redeploy. With no file, uses the latest backup for that CTID. Leaves the CT stopped. |
| `list_backups <ct>` | List the vzdump backups held for a CT on the backup storage. |
| `ct_changed_files <ct>` | Show base-system drift (modified package files + unpackaged config files) to help build the preserve manifest. |

### Backups: storage, retention, rollback

`redeploy_lxc` takes a full `vzdump` of the CT (mode `stop`, zstd) **before**
destroying it — this is the rollback point. It lands on
`$REDEPLOY_BACKUP_STORAGE` (default `local` → `/var/lib/vz/dump/` on the host's
local filesystem). Point it at a NAS dir-storage or a Proxmox Backup Server
datastore by exporting `REDEPLOY_BACKUP_STORAGE=<storage>`.

Retention is automatic: each run passes `--prune-backups
keep-last=$REDEPLOY_BACKUP_KEEP` (default **3**), so only the last N backups per
CT are kept and old ones are pruned — they won't silently fill the disk.

```bash
list_backups 118             # what's held for CT 118
rollback_lxc 118             # restore the newest (then: pct start 118)
rollback_lxc 118 local:backup/vzdump-lxc-118-2026_06_30-10_00_00.tar.zst   # a specific one
```

Flow (on `--apply`): stop docker → tar `/opt` (+ preserve manifest) → **vzdump
backup** → destroy → `pct clone --full` template into the same CTID → stamp
saved config back on → start → restore `/opt` (+ preserved paths, then reboot)
→ `compose_up_all`. Aborts on any failed step with the exact `rollback_lxc`
command to recover.

```bash
redeploy_lxc 118              # preview what would happen
redeploy_lxc 118 --apply      # rebuild CT 118 from template 999
redeploy_lxc 118 debian13 --apply   # rebuild from a named template
rollback_lxc 118             # undo: restore the pre-redeploy backup
```

Config (env vars): `REDEPLOY_TEMPLATE` (default 999), `REDEPLOY_BACKUP_STORAGE`
(default `local`, needs "backup" content), `REDEPLOY_CLONE_STORAGE` (blank =
template's storage), `REDEPLOY_PRESERVE_DIR` (default `/etc/pve/redeploy`).

### convert_to_standard

For each running compose project it:

1. Backs up the compose file + working dir to `/root/compose-migration-<ts>/`.
2. `docker compose down`.
3. Creates `/opt/<project>/` and moves **project-local** bind-mount dirs there
   (sources under the project's working dir). **External/shared** mounts
   (e.g. media on `/mnt`) are reported and left in place.
4. Moves the compose file to `/opt/<project>/docker-compose.yml`.
5. `docker compose up -d` from the new location.

It **aborts on the first failed step** (after `--apply`) so you can inspect.
Always run it without `--apply` first and read the plan.

```bash
convert_to_standard 118            # preview
convert_to_standard 118 --apply    # do it (after backup)
```
