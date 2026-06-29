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

### Protecting containers (denylist)

Opt-out via a **PVE tag**. Any container carrying the protect tag (default
`noauto`) is never converted and is skipped by the bulk helpers:

```bash
pct set 118 --tags noauto          # never touch CT 118
```

Override the tag name per shell with `DOCKER_PROTECT_TAG=mytag`.
(Containers without docker are also skipped automatically.)

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

| Function | What it does |
| --- | --- |
| `redeploy_lxc <ct> [template] [--apply]` | The rebuild. **Dry-run by default** (prints exactly what it will carry over). Template defaults to `$REDEPLOY_TEMPLATE` (999). Refuses protected (`noauto`) CTs and unprivileged-mismatched templates. |
| `rollback_lxc <ct> [backup]` | Restore from the vzdump taken during redeploy. With no file, uses the latest backup for that CTID. Leaves the CT stopped. |

Flow (on `--apply`): stop docker → tar `/opt` → **vzdump backup** → destroy →
`pct clone --full` template into the same CTID → stamp saved config back on →
start → restore `/opt` → `compose_up_all`. Aborts on any failed step with the
exact `rollback_lxc` command to recover.

```bash
redeploy_lxc 118              # preview what would happen
redeploy_lxc 118 --apply      # rebuild CT 118 from template 999
redeploy_lxc 118 debian13 --apply   # rebuild from a named template
rollback_lxc 118             # undo: restore the pre-redeploy backup
```

Config (env vars): `REDEPLOY_TEMPLATE` (default 999), `REDEPLOY_BACKUP_STORAGE`
(default `local`, needs "backup" content), `REDEPLOY_CLONE_STORAGE` (blank =
template's storage).

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
