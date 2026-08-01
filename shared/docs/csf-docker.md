# CSF + Docker: required host configuration

Add this to any server that runs **both** ConfigServer Security & Firewall (CSF)
and Docker. Without it, containers appear to run fine but cannot reach the
outside world, and the symptom looks like an application hang rather than a
firewall problem.

Everything below is host configuration. Nothing here belongs in an application
repository.

---

## Why it is needed

CSF rebuilds iptables from scratch and, in doing so:

- sets the `FORWARD` chain policy to **DROP**
- removes Docker's own chains, including `DOCKER-USER`
- adds allow rules for **only** the interface named in `DOCKER_DEVICE`, which
  defaults to `docker0`

Docker Compose does not use `docker0`. Every Compose project creates its own
bridge, named `br-<id>`, on its own subnet. Those bridges get no rules, so all
of their traffic hits the DROP policy.

The failure is deceptive: **DNS still works**, because Docker's resolver lives
inside the container's own network namespace and never crosses `FORWARD`. So a
container resolves names correctly and then times out on every connection. From
the application's point of view, upstream calls simply hang forever.

---

## The changes

### 1. `/etc/csf/csf.conf` — two values

```ini
# Enable CSF's Docker handling (adds the NAT/masquerade rules).
DOCKER = "1"

# Cover Docker's whole default address pool, not just the legacy bridge.
# Compose networks land on 172.18.x, 172.19.x and upward; the stock value of
# 172.17.0.0/16 only covers the default bridge.
DOCKER_NETWORK4 = "172.16.0.0/12"
```

Also confirm your **SSH port appears in `TCP_IN`** before enabling CSF, or you
will lock yourself out:

```bash
grep -E '^TCP_IN' /etc/csf/csf.conf
grep -E '^Port'   /etc/ssh/sshd_config
```

### 2. `/etc/csf/csfpost.sh` — the part that actually fixes forwarding

The two settings above are necessary but **not sufficient**: they fix NAT, not
the `FORWARD` chain, which stays scoped to `docker0`. CSF runs this hook after
building its rules, so it is the right place to reinstate what Docker would have
installed — for every bridge, not just one.

```bash
#!/bin/bash
# Run by CSF after it rebuilds its rules.
#
# CSF sets FORWARD to DROP and only allows traffic on DOCKER_DEVICE (docker0).
# Docker Compose creates its own bridges named br-<id>, so container traffic on
# those is dropped: DNS still works (that is inside the container's namespace)
# but nothing can reach the outside, which looks like the app hanging.
#
# CSF also removes Docker's own FORWARD/DOCKER-USER chains, so these rules
# reproduce what Docker would have installed, for every br* bridge.
iptables -I FORWARD -i br+ -o br+ -j ACCEPT                                      # container <-> container
iptables -I FORWARD -i br+ '!' -o br+ -j ACCEPT                                  # container -> outside
iptables -I FORWARD -o br+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT  # replies back in
```

```bash
chmod 700 /etc/csf/csfpost.sh
csf -r
```

### 3. Restart Docker once, after CSF

If CSF ran before this was in place it will have torn down Docker's networking —
`docker0` down, NAT chains gone, image pulls failing DNS. One restart rebuilds
it:

```bash
systemctl restart docker
```

Note this bounces every running container.

---

## Verifying

Test **on a Compose network**, not the default bridge. This is the trap: a plain
`docker run` without `--network` uses `docker0`, which CSF already allows, so it
passes while every real container is still blocked.

```bash
# WRONG - passes even when everything is broken
docker run --rm alpine wget -qO- https://example.com

# RIGHT - tests the network your app actually uses
docker network ls
docker run --rm --network <project>_<network> alpine \
  sh -c 'nslookup example.com && wget -q -T 8 -O /dev/null https://example.com && echo OK'
```

Then confirm the rules are present and being hit:

```bash
iptables -L FORWARD -n -v --line-numbers | head
```

Expect `ACCEPT` rules on `br+` with **non-zero packet counts**, and a drop
counter on the chain policy that stops climbing.

Use `-v`. Without it, iptables hides the interface columns — which is exactly
how a `docker0`-only rule can be mistaken for a global allow.

---

## Symptom reference

| What you see | Cause |
| ------------ | ----- |
| Image pulls fail: `lookup … i/o timeout` on a DNS server | Docker's own networking was torn down — restart Docker |
| Container resolves DNS but every connection times out | `FORWARD` drops the Compose bridge — the `csfpost.sh` rules are missing |
| Health check hangs, proxy logs `499` | Same as above: the app is waiting on an upstream it cannot reach |
| Works from `docker run` but not from the app | You tested the default bridge instead of the Compose network |
| Proxy exits with `host not found in upstream` | Unrelated to CSF — see the nginx notes in the template |

---

## Checklist for a new host

- [ ] SSH port present in `TCP_IN`
- [ ] `DOCKER = "1"`
- [ ] `DOCKER_NETWORK4 = "172.16.0.0/12"`
- [ ] `/etc/csf/csfpost.sh` installed, mode 700
- [ ] `csf -r`, then `systemctl restart docker`
- [ ] Egress verified **from a Compose network**
- [ ] SSH still reachable from a second session before you disconnect
