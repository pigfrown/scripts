# pve — Proxmox container helpers

Bash functions for managing Debian LXC containers (run on the Proxmox host).
Source the files to load the functions:

```bash
source ./container_functions.sh
source ./docker_functions.sh   # auto-sources container_functions.sh
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
