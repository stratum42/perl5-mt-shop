# Deploying on IBM Cloud (Production-Licensed Managed Db2)

This guide describes a low-cost, production-licensed IBM Cloud deployment for `perl5-mt-shop` running on a single Linux `x86_64` VPC Virtual Server Instance (`cx2-2x4`) paired with **IBM Cloud Db2 on Cloud (Standard plan)** and local KeyDB.

> **Licensing note**: IBM Db2 Community Edition is licensed for development, testing, and evaluation only, not for production workloads. Use a managed **IBM Cloud Db2 on Cloud Standard** instance (or a commercially licensed Db2/Informix edition) for production.

All prices below are approximate US-South (Dallas) on-demand rates and should be verified against the current IBM Cloud and vendor pricing calculators before provisioning.

---

## Architecture Overview

- **Single VPC VSI (`cx2-2x4`, 2 vCPU / 4 GiB RAM, Ubuntu 24.04 LTS)**: Runs `perl5-mt-shop` (SSHv2 on port `22`, `mojolicious-mt` HTTP ops/webhooks on `127.0.0.1:8088`), local KeyDB (`127.0.0.1:6379`), Caddy TLS (port `443` for Stripe/Shippo webhooks), and the loopback `db2-gateway` connected over TLS (`SECURITY=SSL`) to IBM Cloud Db2 on Cloud.
- **No Code Engine**: IBM Cloud Code Engine only exposes HTTP/HTTPS ingress and does not route raw TCP port `22`/`2222`.
- **No VPC Load Balancer or Public Gateway**: One Floating IP attached to the VSI handles both inbound SSH/HTTPS and outbound API traffic (Stripe, Shippo, Managed Db2), avoiding ~$25/month for a VPC Load Balancer and ~$4.38/month for a separate Public Gateway.

---

## Cost Breakdown (US-South, Production-Licensed)

| Component | Specification | Est. Monthly Cost |
|---|---|---:|
| VPC VSI (`cx2-2x4`) | 2 vCPU, 4 GiB RAM, Ubuntu 24.04 LTS ($0 OS license) | ~$65.00 - $71.00 |
| Boot Volume | 100 GB General Purpose (3 IOPS/GB) | ~$10.00 |
| Floating IP | 1 public IPv4 (inbound + outbound) | ~$4.38 |
| **IBM Cloud Db2 on Cloud (Standard)** | **2 vCPU, 8 GiB RAM, 20 GB storage, 100 GB backups, 500 conns, TLS** | **~$99.00** |
| VPC Outbound Egress | $0.10132/GB: 1,000,000 100-frame SSH sessions = 3.63 GB | ~$0.37 |
| **Estimated Total** | | **~$179 - $185/month** |

Because Db2 runs off-box on the managed Standard plan, the `cx2-2x4` VSI keeps >3 GiB of free RAM for `perl5-mt-shop` (~413 KB/fiber at `MT_FIBER_STACK=32768`) and KeyDB.

---

## Cost Comparison: IBM Cloud vs. AWS ECS/Lambda + PlanetScale HA

Comparing the full production stack (not just the database line item):

| Layer | IBM Cloud `cx2-2x4` + Managed Db2 Standard | AWS ECS/Lambda + PlanetScale HA (Vitess/MySQL) |
|---|---|---|
| **Managed Database** | **IBM Db2 Standard**: ~$99/mo (2 vCPU, 8 GiB RAM, 20 GB storage, 100 GB backups, 500 conns) | **PlanetScale HA (3-node)**: starts ~$39/mo (small shared CPU, 1 GiB RAM, 10 GB storage); ~$100 - $199+/mo at 2 vCPU / 8 GiB parity |
| **App Compute** | 1x `cx2-2x4` VSI: ~$65 - $71/mo (SSH + HTTP webhooks + KeyDB in one host) | ECS Fargate (2 vCPU / 4 GiB): ~$65 - $130/mo + Lambda API invocations |
| **Networking** | 1x Floating IP: ~$4.38/mo (no NLB, no NAT Gateway) | NLB (~$18/mo + LCU) + NAT Gateway (~$32/mo + data processing) |
| **Boot Storage** | 100 GB block volume: ~$10/mo | Included / ephemeral ECS storage |
| **Egress (1M sessions)** | **~$0.37** (3.63 GB with cell-diff + `zlib@openssh.com`) | ~$22 - $25 (uncompressed SSH ANSI + internal NAT/API hops) |
| **Estimated Total** | **~$179 - $185/month** | **~$176 - $350+/month** (depending on DB compute size and egress) |

### Key Trade-offs Between the Two Database Tiers

- **Where IBM Cloud Db2 Standard fits well**:
  - Includes 2 vCPU and 8 GiB RAM at the $99/month base tier, along with 100 GB of backup storage.
  - Supports `DECFLOAT(34)` (exact 34-digit IEEE 754-2008 decimal128 matching `MT::Decimal`), `SYSTEM_TIME` temporal history tables, `SELECT FROM FINAL TABLE`, `MERGE INTO`, `GROUP BY ROLLUP`, and static compiled SQL PL stored procedures (`DB2_SP_ONLY=1`).
- **Where PlanetScale fits well**:
  - Lower entry floor (~$39/month) if you only need a very small HA MySQL/Vitess cluster (1 GiB RAM, 10 GB storage).
  - Built-in schema branching, non-blocking online DDL, and horizontal Vitess sharding if the workload grows beyond a single database node.

*(If you want an even lower monthly bill for a single-node non-HA storefront without a managed database fee, `perl5-mt-shop` also supports `--db-driver sqlite` on a single `cx2-2x4` VSI for ~$80 - $86/month, with periodic WAL backups to IBM Cloud Object Storage.)*

---

## 1. Provision Managed Db2 Standard and VPC (`ibmcloud`)

Install the IBM Cloud CLI and VPC plugin (`ibmcloud plugin install vpc-infrastructure`), then target `us-south`:

```sh
ibmcloud login --sso
ibmcloud target -r us-south -g Default

# 1. Provision IBM Cloud Db2 on Cloud (Standard plan)
ibmcloud resource service-instance-create shop-db2 dashdb-for-transactions standard us-south
ibmcloud resource service-key-create shop-db2-key Administrator --instance-name shop-db2
ibmcloud resource service-key shop-db2-key --output json > /tmp/db2_creds.json
# Note hostname, port (typically 30000-32767), db (bludb), username, password, and ssl=true
```

Provision the VPC, security group, `cx2-2x4` VSI, and Floating IP:

```sh
ibmcloud is vpc-create shop-vpc
VPC_ID=$(ibmcloud is vpcs --output json | jq -r '.[] | select(.name=="shop-vpc") | .id')

ibmcloud is subnet-create shop-sub-1 "$VPC_ID" \
  --zone us-south-1 --ipv4-address-count 16
SUBNET_ID=$(ibmcloud is subnets --output json | jq -r '.[] | select(.name=="shop-sub-1") | .id')

ibmcloud is sg-create shop-sg "$VPC_ID"
SG_ID=$(ibmcloud is sgs --output json | jq -r '.[] | select(.name=="shop-sg") | .id')

# Public storefront SSH (22), HTTPS webhooks (443), ACME HTTP-01 (80)
ibmcloud is sg-rulec "$SG_ID" inbound tcp --port-min 22 --port-max 22
ibmcloud is sg-rulec "$SG_ID" inbound tcp --port-min 80 --port-max 80
ibmcloud is sg-rulec "$SG_ID" inbound tcp --port-min 443 --port-max 443
# Host administration SSH (restrict to your static admin IP/CIDR)
ibmcloud is sg-rulec "$SG_ID" inbound tcp --port-min 22022 --port-max 22022 --remote YOUR_IP/32
ibmcloud is sg-rulec "$SG_ID" outbound all

ibmcloud is key-create shop-admin-key @~/.ssh/id_ed25519.pub
KEY_ID=$(ibmcloud is keys --output json | jq -r '.[] | select(.name=="shop-admin-key") | .id')

IMAGE_ID=$(ibmcloud is images --visibility public --output json \
  | jq -r '[.[] | select(.name | startswith("ibm-ubuntu-24-04")) | select(.status=="available")][0].id')

ibmcloud is instance-create shop-vsi-1 "$VPC_ID" us-south-1 cx2-2x4 "$SUBNET_ID" \
  --image "$IMAGE_ID" --keys "$KEY_ID" --security-groups "$SG_ID"

NIC_ID=$(ibmcloud is instance shop-vsi-1 --output json | jq -r '.primary_network_interface.id')
ibmcloud is floating-ip-reserve shop-fip --nic "$NIC_ID"
ibmcloud is floating-ip shop-fip --output json | jq -r '.address'
```

Ports `50050` (`db2-gateway`), `6379` (KeyDB), and `8088` (`mojolicious-mt` ops/metrics) remain bound strictly to `127.0.0.1` and are never exposed in `shop-sg`.

---

## 2. Host Setup (Move System `sshd` to Port `22022`)

```sh
ssh root@<FLOATING_IP>

cat >/etc/ssh/sshd_config.d/99-shop-admin.conf <<'EOF'
Port 22022
PasswordAuthentication no
PermitRootLogin prohibit-password
EOF
systemctl restart ssh

# Verify port 22022 in a second terminal before closing this session:
# ssh -p 22022 root@<FLOATING_IP>

apt-get update
apt-get install -y \
  build-essential git pkg-config curl jq sqlite3 \
  libsodium-dev libssl-dev zlib1g-dev \
  docker.io docker-compose-v2 caddy

useradd -m -s /bin/bash shop
usermod -aG docker shop
```

---

## 3. Build `perl5-mt`, `mojolicious-mt`, and `perl5-mt-shop`

On Linux `x86_64`, `perl5-mt` requires `-Ud_thread_local` and `-Accflags='-std=gnu17'` (for GCC 15+):

```sh
su - shop
mkdir -p ~/src && cd ~/src

git clone <perl5-mt-repo-url> perl5-mt
cd perl5-mt
./Configure -des -Dusethreads -Ud_thread_local \
  -Dprefix=/opt/perl5-mt -Accflags='-std=gnu17' -Doptimize='-O2 -g'
make -j$(nproc)
sudo make install

cd ~/src
git clone <mojolicious-mt-repo-url> mojolicious-mt
cd mojolicious-mt/xs && /opt/perl5-mt/bin/perl Makefile.PL && make
cd ../xs-keydb && /opt/perl5-mt/bin/perl Makefile.PL && make

cd ~/src
git clone <perl5-mt-shop-repo-url> perl5-mt-shop
cd perl5-mt-shop
make PERL=/opt/perl5-mt/bin/perl PERL_LIB=/opt/perl5-mt/lib/5.40.2 crypto hostkey
```

---

## 4. Connect `db2-gateway` (TLS) and Local KeyDB

Point `db2-gateway` at your IBM Cloud Db2 on Cloud Standard credentials using TLS (`DB2_DSN` with `SECURITY=SSL`) and run local KeyDB alongside it:

```sh
cd ~/src/perl5-mt-shop

cat > docker/.env <<'EOF'
DB2_HOST=<your-db2-host>.databases.appdomain.cloud
DB2_PORT=<your-db2-tls-port>
DB2_DATABASE=bludb
DB2_USER=<your-db2-username>
DB2_PASSWORD=<your-db2-password>
DB2_SECURITY=SSL
DB2_SP_ONLY=1
DB2_ADMIN_KEY=<strong-random-admin-key>
KEYDB_PORT=6379
EOF
chmod 600 docker/.env

# Start only the lightweight loopback db2-gateway and KeyDB (no local Db2 container needed)
docker compose -f docker/docker-compose.yml up -d --build db2-gateway keydb

# Bootstrap schema, 42 static SQL PL stored procedures, and seed data
DB2_ADMIN_KEY=<strong-random-admin-key> ./docker/init-db2.sh
```

Remove or rotate `DB2_ADMIN_KEY` after schema initialization so the `/admin/ddl` endpoint cannot be used at runtime.

---

## 5. Run `perl5-mt-shop` Under `systemd` and Caddy TLS

Create `/etc/perl5-mt-shop.env` (mode `0600`, owned by `shop`):

```sh
MT_FIBER_STACK=32768
KEYDB_PORT=6379
STRIPE_SECRET_KEY=sk_live_...
STRIPE_WEBHOOK_SECRET=whsec_...
SHIPPO_API_TOKEN=shippo_live_...
SHIPPO_WEBHOOK_SECRET=...
```

Create `/etc/systemd/system/perl5-mt-shop.service`:

```ini
[Unit]
Description=perl5-mt-shop SSHv2 Storefront
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=shop
Group=shop
WorkingDirectory=/home/shop/src/perl5-mt-shop
EnvironmentFile=/etc/perl5-mt-shop.env
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=65536
ExecStart=/opt/perl5-mt/bin/perl \
  -I/home/shop/src/perl5-mt-shop/lib \
  -I/home/shop/src/perl5-mt-shop/xs/Shop-SSH-Crypto/blib/lib \
  -I/home/shop/src/perl5-mt-shop/xs/Shop-SSH-Crypto/blib/arch \
  -I/home/shop/src/mojolicious-mt/lib \
  -I/home/shop/src/mojolicious-mt/xs/blib/lib \
  -I/home/shop/src/mojolicious-mt/xs/blib/arch \
  /home/shop/src/perl5-mt-shop/bin/shop-server \
  --db-driver db2 --host 0.0.0.0 --port 22 --ops-host 127.0.0.1 --ops-port 8088
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Enable the service and configure `/etc/caddy/Caddyfile` to terminate HTTPS for webhooks while keeping `/metrics` loopback-only:

```caddyfile
shop.example.com {
    handle /webhooks/* {
        reverse_proxy 127.0.0.1:8088
    }
    handle /api/catalog {
        reverse_proxy 127.0.0.1:8088
    }
    handle /healthz {
        reverse_proxy 127.0.0.1:8088
    }
    handle {
        respond "Connect over SSH: ssh shop.example.com" 200
    }
}
```

```sh
systemctl daemon-reload
systemctl enable --now perl5-mt-shop
systemctl reload caddy
```

Point DNS `A shop.example.com` at the Floating IP and verify:

```sh
ssh -C shop.example.com
curl -s https://shop.example.com/healthz
```

---

## Cost-Control Checklist

1. **Keep `zlib@openssh.com` enabled**: At 3.63 GB per 1,000,000 100-frame sessions, IBM Cloud VPC outbound egress stays around $0.37 per million sessions.
2. **Keep `MT_FIBER_STACK=32768`**: Keeps per-session RSS around ~413 KB, so a `cx2-2x4` VSI handles thousands of concurrent sessions without scaling compute.
3. **Skip VPC Load Balancer and Public Gateway**: One Floating IP handles both inbound SSH/HTTPS and outbound APIs for a single-VSI shop.
4. **Use IBM Cloud private endpoints where available**: Connecting to IBM Cloud Db2 on Cloud and IBM Cloud Object Storage over the private service network avoids public egress billing on database and backup traffic.
