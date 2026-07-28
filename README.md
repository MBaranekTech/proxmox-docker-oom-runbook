# Proxmox + Docker OOM Runbook

A practical field guide for **diagnosing, recovering from, and preventing
out-of-memory (OOM) incidents** where a single unbounded container consumes all
RAM and takes down an entire Proxmox VM.

> **Based on a real incident.** A PHP-FPM container with **no memory limit** grew
> into multi-gigabyte territory (>2.3 GB RSS). The kernel OOM killer fired
> repeatedly, and because the container had no cgroup limit, the OOM was
> *global* — it eventually froze the whole VM in an OOM/thrashing loop until the
> VM was hard-reset from the hypervisor.

---

## Table of contents

- [TL;DR](#tldr)
- [1. Symptoms — how to recognize it](#1-symptoms--how-to-recognize-it)
- [2. Diagnosis — commands to look at](#2-diagnosis--commands-to-look-at)
- [3. Recovery — the VM is frozen](#3-recovery--the-vm-is-frozen)
- [4. Prevention — so it doesn't happen again](#4-prevention--so-it-doesnt-happen-again)
- [5. Reading an OOM-kill log line](#5-reading-an-oom-kill-log-line)
- [Repo layout](#repo-layout)
- [Push this to GitHub](#push-this-to-github)

---

## TL;DR

1. **VM frozen?** From the **Proxmox host**: `qm reset <vmid>` (hard reset). Do **not**
   use `qm shutdown` — a frozen guest can't answer ACPI.
2. **Find the culprit.** From the **VM**: `journalctl -b -1 -k | grep -iE "oom|killed"`.
   The `task_memcg=/system.slice/docker-<id>.scope` line names the container's cgroup.
3. **Add a safety net.** Give the container a memory limit so the next OOM kills
   *the container*, not the whole VM:
   `docker update --memory 3g --memory-swap 3g <container>`.
4. **Fix the root cause.** The limit only contains the blast radius; the leaking /
   heavy process still needs fixing.

The core insight: **a container without a memory limit can trigger a *global* OOM
that takes down the whole host.** With a limit, the OOM is confined to that
container's cgroup.

---

## 1. Symptoms — how to recognize it

- VM completely **unreachable** — no SSH, and the noVNC/serial console doesn't
  respond to input (including `Ctrl+Alt+Del`).
- Kernel log full of:
  ```
  Out of memory: Killed process <pid> (php) total-vm:...kB, anon-rss:...kB, ...
  ```
- Often preceded by:
  ```
  INFO: task <name>:<pid> blocked for more than 120 seconds.
  ```
  These `hung_task` warnings mean processes were stuck waiting on I/O — typical
  under heavy swap thrashing.
- The same **RSS keeps climbing** across kills (e.g. 1.4 → 2.0 → 2.1 → 2.3 GB),
  which points to a leak or a periodic job that reprocesses a growing dataset.

---

## 2. Diagnosis — commands to look at

> Run these **on the VM** unless noted. Some need `sudo`/root or membership in the
> `docker` group.

### Is memory actually the problem?

```bash
free -h                 # total / used / available RAM + swap
docker stats --no-stream   # per-container MEM USAGE / LIMIT — spot the outlier
```

A container showing its `LIMIT` as the **full VM RAM** has **no limit set** — that's
your risk.

### Which container caused it? (from the kernel log)

```bash
journalctl -b -1 -k | grep -iE "oom|killed"     # previous boot (after a reset)
journalctl -k        | grep -iE "oom|killed"     # current boot
```

Look for this line — the cgroup path identifies the container:

```
oom-kill:constraint=CONSTRAINT_NONE,...,task_memcg=/system.slice/docker-ed2f8d6...c7.scope,task=php,...
```

Resolve the cgroup ID to a container name:

```bash
docker ps -a --no-trunc | grep <first-12-chars-of-id>
# or:
docker inspect --format '{{.Name}}  {{.Config.Image}}' <id>
```

> **Note:** a container's ID is stable across reboots. It only changes if the
> container is **re-created** (e.g. `docker compose up -d` after a config/image
> change), so the ID from the log usually still matches a running container.

### What is running inside it, and what's the memory limit?

```bash
docker exec <container> ps aux --sort=-rss | head -15
docker exec <container> php -r 'echo ini_get("memory_limit"), PHP_EOL;'
docker logs --since 24h <container> | less
```

CLI PHP jobs frequently run with `memory_limit = -1` (unlimited), which is exactly
what lets a single process grow into gigabytes.

### List containers that have NO memory limit

```bash
docker ps -q | while read -r id; do
  lim=$(docker inspect -f '{{.HostConfig.Memory}}' "$id")
  [ "$lim" = "0" ] && docker inspect -f '{{.Name}}  (no limit)  image={{.Config.Image}}' "$id"
done
```

`scripts/diagnose-oom.sh` in this repo runs the whole read-only triage in one go.

---

## 3. Recovery — the VM is frozen

When the guest is frozen, act from the **Proxmox host** (SSH to the node, *not* the
VM). Find the VM ID first:

```bash
qm list
```

| Goal | Command | Notes |
|------|---------|-------|
| Hard reset (reset button) | `qm reset <vmid>` | Fastest. Works while the guest is stuck. |
| Hard power cycle | `qm stop <vmid>` then `qm start <vmid>` | Equivalent to pulling the plug, then on. |
| Locked VM (e.g. after a stuck backup/shutdown) | `qm unlock <vmid>` then `qm stop <vmid>` | Clears the config lock. |
| QEMU process itself stuck | `kill -9 $(cat /var/run/qemu-server/<vmid>.pid)` then `qm start <vmid>` | Last resort. |

**Do NOT use `qm shutdown`** — it sends an ACPI power signal the frozen guest can't
answer, so the command just hangs until timeout. Same reason `Ctrl+Alt+Del` in the
noVNC console does nothing: it's delivered to a guest that can't react.

The **GUI** equivalent: select the VM → arrow next to **Shutdown** → **Stop**
(not Shutdown) / **Reset**.

After it boots, grab the previous-boot logs *while they're fresh* (see section 2).

---

## 4. Prevention — so it doesn't happen again

### a) Put a memory limit on the container (most important)

Applies **live**, no restart, no downtime:

```bash
docker update --memory 3g --memory-swap 3g <container>
```

- Setting `--memory-swap` **equal to** `--memory` means the container **can't swap** —
  swap thrashing is what froze the VM in the first place.
- Verify — `LIMIT` should now show your value instead of the full VM RAM:
  ```bash
  docker stats --no-stream | grep <container>
  ```
- If you see `WARNING: ... kernel does not support swap limit capabilities`, the
  memory limit itself still applies; only the swap cap is ignored.

With a limit in place, the next OOM is contained: the kernel kills the offending
process **inside the container's cgroup** (`constraint=CONSTRAINT_MEMCG`) and the
rest of the host keeps running.

### b) Make the limit persistent (Docker Compose)

`docker update` survives container restarts and host reboots, but is lost if the
container is **re-created**. Find how it's managed:

```bash
docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' <container>
```

If that prints a path, it's Compose — add to the service in `docker-compose.yml`:

```yaml
services:
  <service>:
    mem_limit: 3g
    memswap_limit: 3g
    # Compose v3 / Swarm equivalent:
    # deploy:
    #   resources:
    #     limits:
    #       memory: 3g
```

This takes effect on the next `docker compose up -d` (a brief container re-create).

### c) Size the limit sensibly

Leave headroom for the OS **and** the other containers. Rule of thumb:

```
sum(container limits) + host/OS reserve  <=  total VM RAM
```

Example: an 8 GiB VM where everything else uses ~2.4 GiB can safely give one
container a 3 GiB cap and still keep >2 GiB free for the system.

### d) Give the VM more RAM (Proxmox)

From the **Proxmox host**. Proxmox takes memory in **MiB** (the GUI labels the field
MiB; people often say "MB"). `12 GiB = 12 × 1024 = 12288`:

```bash
qm set <vmid> --memory 12288
```

Check the current config and whether ballooning is in play first:

```bash
qm config <vmid> | grep -Ei 'memory|balloon'
```

- **Balloon off / not set** (fixed memory): raising the maximum needs a full
  **stop + start** (`qm stop` / `qm start`), not just a reboot inside the guest.
- **Balloon on**: ballooning only varies *usage* between a minimum and the configured
  maximum; to raise the maximum reliably, still do a stop/start unless memory
  hotplug is explicitly configured.
- Make sure the **host** actually has the extra RAM free (`free -h` on the node),
  minus a reserve for Proxmox itself and ZFS ARC if ZFS is in use.

More RAM eases the pressure but does **not** replace a per-container limit — a
runaway process can still grow to fill whatever you give it.

### e) Fail earlier and see it coming

- **earlyoom** — a userspace daemon that kills a chosen process *before* the kernel
  hits a hard, thrashing OOM, keeping the box responsive:
  ```bash
  sudo apt install earlyoom
  sudo systemctl enable --now earlyoom
  ```
- **Monitoring/alerting** — if you already run `node-exporter`, wire a Prometheus +
  Alertmanager rule on available memory (and per-container `container_memory_*` from
  cAdvisor) so you're paged *before* the VM freezes.

### f) Fix the root cause

The limit only contains the damage. Find and fix the leaking / heavy job:

```bash
docker stats                       # watch memory climb in real time
docker exec <container> ps aux --sort=-rss | head   # catch the exact command line
docker logs --since 24h <container>
```

Typical fixes: batch the workload into smaller chunks, set a sane `memory_limit`
for the CLI process, or fix the leak in the application code.

---

## 5. Reading an OOM-kill log line

```
Out of memory: Killed process 1960337 (php) total-vm:1684832kB, anon-rss:1467952kB, file-rss:0kB, shmem-rss:0kB, UID:33 pgtables:3092kB oom_score_adj:0
```

| Field | Meaning |
|-------|---------|
| `1960337 (php)` | PID and name of the killed process |
| `total-vm` | Total virtual memory it had mapped |
| `anon-rss` | **Anonymous resident memory** — actual physical RAM in use (the number that matters) |
| `file-rss` / `shmem-rss` | RAM backed by files / shared memory |
| `UID:33` | Owner — `33` = `www-data` on Debian/Ubuntu |
| `oom_score_adj` | OOM "kill priority" bias for this process |

And the decisive line:

```
oom-kill:constraint=CONSTRAINT_NONE,...,task_memcg=/system.slice/docker-<id>.scope,...
```

| Value | Meaning |
|-------|---------|
| `constraint=CONSTRAINT_NONE` + `global_oom` | **System-wide** OOM — no cgroup limit was hit. The whole host was out of RAM. This is the dangerous case. |
| `constraint=CONSTRAINT_MEMCG` | A **cgroup/container hit its own limit** — the kill is contained to that container. This is what a memory limit buys you. |
| `task_memcg=.../docker-<id>.scope` | The cgroup the killed task belonged to → identifies the **container**. |

---

## Repo layout

```
proxmox-docker-oom-runbook/
├── README.md                 # this guide
├── COMMANDS.md               # quick-reference cheatsheet, grouped by task
├── scripts/
│   └── diagnose-oom.sh       # read-only triage script (changes nothing)
├── .gitignore
└── LICENSE
```

---

## Push this to GitHub

```bash
cd proxmox-docker-oom-runbook
git init
git add .
git commit -m "Add Proxmox + Docker OOM runbook"
git branch -M main
git remote add origin git@github.com:<you>/<repo>.git
git push -u origin main
```

---

*Placeholders like `<vmid>`, `<container>`, `<service>`, `<you>` should be replaced
with your real values. Commands that touch the hypervisor run on the **Proxmox
host**; the rest run inside the **VM**.*
