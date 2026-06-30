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
| `check_volumes <ct>` | Report docker **volume** mounts (named/anonymous) on running containers — data that would NOT survive a redeploy. | 0 none / 1 volumes / 2 n/a |
| `check_all_volumes` | Run `check_volumes` across every eligible container (skips protected). | — |
| `migrate_volumes_to_binds <ct> [--apply] [--force]` | Copy each **named** volume's data into a project-local bind mount (`<workdir>/volumes/<name>`), rewrite the compose file, restart, and verify — so `convert_to_standard` can then run. **Dry-run by default.** | 0/1/2 |
| `migrate_all_volumes [--apply] [--force]` | Run the migration across every eligible container. **Dry-run by default**. | — |

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
rollback_lxc 118 /var/lib/vz/dump/vzdump-lxc-118-2026_06_30-10_00_00.tar.zst   # a specific one
rollback_lxc 118 <file> --storage=local-lvm   # force the rootfs storage
```

`rollback_lxc` restores the rootfs to the CT's current rootfs storage (detected
from its config); if the CT no longer exists, pass `--storage=<id>`. It does
**not** default to `local` — `local` can't hold a container rootfs.

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

### Docker volumes → bind mounts (`migrate_volumes_to_binds`)

`convert_to_standard` (and `redeploy_lxc`) only carry data that lives on the
filesystem under the project tree. Named/anonymous **docker volumes** live in
docker's own storage, so they'd be left behind — which is why
`convert_to_standard` **refuses** a container that still has volume mounts and
points you here.

`migrate_volumes_to_binds` copies each **named** volume into a project-local
bind mount and rewrites the compose file so the stack uses it instead:

1. Discovers volume mounts from running containers' compose labels.
2. **Backs up** the compose file and tars each volume to
   `/root/volume-migration-<ts>/`.
3. `docker-compose down` — **without `-v`**, so the volumes are *not* deleted.
4. For each named volume `V` (mounted at `DEST`): copies its contents (mounted
   **read-only**, `cp -a`) into `<workdir>/volumes/V`, then rewrites the
   `V:DEST` reference in the compose file to `<workdir>/volumes/V:DEST`.
5. `docker-compose up -d`, then **verifies**: the stack no longer mounts the
   migrated volumes, and each bind dir matches its source volume (file count +
   total bytes). On any failure it prints the exact restore-from-backup command
   and never removes anything.

The original named volumes are **left in place** as a rollback net — the
function prints the `docker volume rm` commands to run once you're confident.
Because they survive, recovery from a bad migration is just: restore the
backed-up compose file and `up -d`.

> **Anonymous volumes** (image `VOLUME` or a bare `- /path` line) can't be
> rewritten unambiguously, so they're backed up and **reported but left in
> place**. If any remain, `convert_to_standard` still refuses until you handle
> them by hand.

Intended order — **always dry-run first**:

```bash
check_volumes 118                       # see what's in volumes
migrate_volumes_to_binds 118            # preview the migration
migrate_volumes_to_binds 118 --apply    # copy data, rewrite compose, verify
check_volumes 118                       # confirm: no volumes left
convert_to_standard 118 --apply         # now it proceeds
# once happy:
pct exec 118 -- docker volume rm <name> # remove the old (now-orphaned) volumes
```

Config: `DOCKER_MIGRATE_IMAGE` (default `alpine`) — the throwaway image used to
read volumes and copy/tar their contents. Pass `--force` to write into a target
bind dir that already exists and is non-empty.

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
