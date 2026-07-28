# Commands cheatsheet

Quick reference for OOM triage and remediation. Grouped by task.

- Commands marked **[host]** run on the **Proxmox host** (SSH to the node).
- All others run **inside the VM**.
- Replace `<vmid>`, `<container>` with your values. Some commands need `sudo`/root.

---

## Host memory & swap (VM)

```bash
free -h                         # RAM + swap overview
cat /proc/meminfo | head -5     # detailed breakdown
vmstat 1 5                      # si/so columns > 0 = actively swapping (bad)
```

Top swap users (a sign of thrashing):

```bash
for f in /proc/*/status; do
  awk '/^Name:/{n=$2} /^VmSwap:/{if($2+0>0) print $2, n}' "$f" 2>/dev/null
done | sort -rn | head
```

---

## Docker — what's running & what's eating RAM

```bash
docker ps                                   # running containers
docker stats --no-stream                    # live memory per container (MEM USAGE / LIMIT)
docker stats --no-stream \
  --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}'
```

Containers with **no memory limit** (`Memory == 0`):

```bash
docker ps -q | while read -r id; do
  lim=$(docker inspect -f '{{.HostConfig.Memory}}' "$id")
  [ "$lim" = "0" ] && docker inspect -f '{{.Name}}  (no limit)  {{.Config.Image}}' "$id"
done
```

Inspect one container:

```bash
docker inspect --format '{{.Name}}  {{.Config.Image}}' <container>
docker exec <container> ps aux --sort=-rss | head -15
docker exec <container> php -r 'echo ini_get("memory_limit"), PHP_EOL;'   # if PHP
docker logs --since 24h <container> | less
```

---

## Kernel logs — OOM evidence (VM)

```bash
journalctl -k | grep -iE "oom|killed"          # current boot
journalctl -b -1 -k | grep -iE "oom|killed"     # previous boot (after a reset)
dmesg -T | grep -iE "out of memory|oom-kill"    # alternative, human-readable time
```

Map the killer's cgroup to a container:

```bash
# take the docker-<id>.scope from the task_memcg=... line, then:
docker ps -a --no-trunc | grep <first-12-chars-of-id>
```

---

## Set / change container memory limit (VM)

Live, no restart:

```bash
docker update --memory 3g --memory-swap 3g <container>   # 3g cap, no swap
docker stats --no-stream | grep <container>              # verify LIMIT changed
```

Persistent (Compose) — in `docker-compose.yml`:

```yaml
services:
  <service>:
    mem_limit: 3g
    memswap_limit: 3g
```

Find the compose project dir for a container:

```bash
docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' <container>
```

---

## Recover a frozen VM  **[host]**

```bash
qm list                                   # find the VMID
qm reset <vmid>                           # hard reset (preferred for a frozen guest)

qm stop <vmid> && qm start <vmid>         # hard power cycle

qm unlock <vmid> && qm stop <vmid>        # if the VM config is locked

# last resort — QEMU process itself stuck:
kill -9 $(cat /var/run/qemu-server/<vmid>.pid) && qm start <vmid>
```

> Never `qm shutdown` a frozen guest — ACPI won't be answered; the command hangs.

---

## Change VM RAM  **[host]**

Proxmox memory is in **MiB** (`12 GiB = 12288`):

```bash
qm config <vmid> | grep -Ei 'memory|balloon'   # check current setup first
qm set <vmid> --memory 12288                    # set to 12 GiB
```

- Fixed memory (no balloon): apply with a full **stop + start**.
- Confirm the host has the RAM free: `free -h`  **[host]**

---

## Optional hardening (VM)

```bash
sudo apt install earlyoom
sudo systemctl enable --now earlyoom     # kills a process before a hard OOM/thrash
```
