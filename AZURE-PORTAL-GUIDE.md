# Azure Portal setup guide — Aabha multi-tier architecture (no Bicep)

Everything here is done by clicking through **portal.azure.com**. Follow the
sections in order — each one depends on resources created in the previous
section.

Estimated time: 60-90 minutes. Estimated cost while running: roughly
$4-8/day (mostly the App Gateway and the two VMSS instances) — **delete
the resource group when you're done experimenting** (last section).

---

## 0. Create a Resource Group

1. Search **"Resource groups"** → **+ Create**
2. Subscription: your subscription. Name: `rg-aabha-dev`. Region: pick one
   close to you (e.g. **Central India** or **South East Asia** if you're in
   Nepal) — use the **same region for every resource below**.
3. **Review + create** → **Create**

---

## 1. Virtual Network + 4 subnets

1. Search **"Virtual networks"** → **+ Create**
2. **Basics**: Resource group `rg-aabha-dev`, Name `aabha-vnet`, Region: same as above.
3. **IP Addresses** tab: set address space to `10.0.0.0/16`, delete the
   default subnet, then **+ Add subnet** four times:

   | Subnet name | Address range | Notes |
   |---|---|---|
   | `snet-appgw` | `10.0.0.0/26` | Application Gateway |
   | `snet-web` | `10.0.1.0/24` | VMSS (app tier) |
   | `snet-data` | `10.0.2.0/24` | MySQL — under **Subnet delegation**, select **Microsoft.DBforMySQL/flexibleServers** |
   | `AzureBastionSubnet` | `10.0.3.0/26` | must be named exactly this |

4. **Review + create** → **Create**

---

## 2. Network Security Groups (the "security groups")

Create three NSGs and attach each to its subnet.

### nsg-web
1. Search **"Network security groups"** → **+ Create** → name `nsg-web`, same RG/region.
2. After creation, open it → **Inbound security rules** → **+ Add**:
   - Source: **IP Addresses**, Source IP: `10.0.0.0/26` (the App Gateway subnet), Destination: Any, Service: **HTTP** (port 80), Action: **Allow**, Priority `100`, Name `Allow-HTTP-From-AppGw`
3. Leave the rest as default (Azure's built-in rules already deny all other inbound from the internet).
4. Go to **Subnets** (left menu) → **+ Associate** → pick `aabha-vnet` → `snet-web`.

### nsg-data
1. Create NSG `nsg-data`.
2. Inbound rule: Source **IP Addresses** `10.0.1.0/24` (the web subnet), Destination: Any, Destination port: `3306`, Protocol TCP, Action **Allow**, Priority `100`, Name `Allow-MySQL-From-Web`.
3. **Subnets** → **+ Associate** → `snet-data`.

### nsg-appgw
1. Create NSG `nsg-appgw`.
2. Add two inbound rules (these are required by Azure for Application Gateway v2 to work):
   - Priority `100`: Source **Any**, Destination port `80`, Protocol TCP, Allow, name `Allow-HTTP-Inbound`
   - Priority `110`: Source **Service Tag** → `GatewayManager`, Destination port range `65200-65535`, Protocol TCP, Allow, name `Allow-GatewayManager-Inbound`
3. **Subnets** → **+ Associate** → `snet-appgw`.

---

## 3. NAT Gateway (outbound internet for the private data subnet)

1. Search **"NAT gateways"** → **+ Create**.
2. Basics: RG `rg-aabha-dev`, name `aabha-natgw`, region same, Idle timeout `10`.
3. **Outbound IP** tab: **+ Create a public IP**, name `aabha-pip-natgw`, SKU Standard.
4. **Subnet** tab: Virtual network `aabha-vnet` → check **`snet-data`**.
5. **Review + create** → **Create**.

This is what lets the (otherwise fully private) database subnet reach the
internet for OS patching — outbound only, nothing can initiate a connection
*into* that subnet from outside.

---

## 4. MySQL Flexible Server (private, VNet-injected)

1. Search **"Azure Database for MySQL flexible servers"** → **+ Create**.
2. **Basics**: RG `rg-aabha-dev`, Server name `aabha-mysql` (must be globally unique — add your initials if taken), Region same, MySQL version `8.0`.
   - Workload type: **Development**
   - Compute + storage: click **Configure server** → Burstable → `Standard_B1ms` → Save.
   - Set an admin username and a strong password — **write these down**.
3. **Networking** tab: choose **Private access (VNet Integration)**.
   - Virtual network: `aabha-vnet`, Subnet: `snet-data`.
   - Private DNS zone: click **Create new**, accept the default name (`privatelink.mysql.database.azure.com`) — the portal links it to your VNet automatically.
4. **Review + create** → **Create**. This step takes the longest (~10-15 min).
5. Once created, note the **server name** shown on the Overview page, e.g.
   `aabha-mysql.mysql.database.azure.com` — you'll need it in step 6.

### Load the schema
Because this server has no public endpoint, you need something *inside*
the VNet to connect to it — use Azure Bastion + a VMSS instance (set up in
step 6-7) once they exist, or temporarily use Cloud Shell with VNet
integration. Simplest path: come back to this after step 7, then from a
VMSS instance (reached via Bastion):

```bash
sudo apt-get install -y mysql-client
mysql -h aabha-mysql.mysql.database.azure.com -u <admin-user> -p < /dev/stdin
```
and paste in the contents of `database/schema.sql`, plus create the app user:
```sql
CREATE USER 'restaurant_app'@'%' IDENTIFIED BY 'the-password-you-will-put-in-cloud-init';
GRANT SELECT, INSERT, UPDATE ON restaurant_db.* TO 'restaurant_app'@'%';
FLUSH PRIVILEGES;
```

---

## 5. Application Gateway (the public entry point)

1. Search **"Application Gateway"** → **+ Create**.
2. **Basics**: RG `rg-aabha-dev`, name `aabha-agw`, Region same, Tier **Standard V2**, Enable autoscaling: **Yes**, Min `2` / Max `5`.
3. **Frontends**: Frontend IP type **Public** → **Add new** public IP `aabha-pip-agw`.
4. **Backends**: **+ Add a backend pool** → name `pool-web` → **Add backend pool without targets for now** (you'll wire it to the VMSS in step 6) → Save.
5. **Configuration**: **+ Add a routing rule**:
   - Rule name `rule-http`
   - Listener: name `listener-http`, Frontend IP **Public**, Port `80`, Protocol **HTTP**
   - Backend targets: Backend pool `pool-web`
   - **Backend settings** → **+ Add new**: Backend protocol **HTTP**, port `80`, create a **custom probe**:
     - Probe name `probe-health`, Protocol HTTP, Path `/api/health.php`, Interval `30`
6. **Review + create** → **Create**.

---

## 6. VMSS — the application tier (Apache + PHP)

1. Search **"Virtual machine scale sets"** → **+ Create**.
2. **Basics**:
   - RG `rg-aabha-dev`, VMSS name `aabha-vmss-web`, Region same.
   - Orchestration mode: **Uniform**.
   - Image: **Ubuntu Server 22.04 LTS - x64 Gen2**.
   - Size: `Standard_B2s`.
   - Authentication: **SSH public key** (paste your public key, or let Azure generate one for you and download it).
   - Instance count: `2`.
3. **Disks**: leave defaults (Standard SSD is fine for a demo).
4. **Networking**:
   - Virtual network `aabha-vnet`, Subnet `snet-web`.
   - Public IP: **No public IP** (leave unchecked — instances must not be internet-facing).
   - NIC network security group: **None** (already enforced at the subnet level by `nsg-web`).
   - **Load balancing**: toggle **On** → Load balancing options: **Application Gateway** → select `aabha-agw` → Backend pool `pool-web`.
5. **Scaling**:
   - Scaling policy: **Custom**.
   - Instance limits: Minimum `2`, Maximum `6`, Default `2`.
   - **+ Add a scale condition** → Metric source: Host metrics → Metric name: **Percentage CPU** → Operator **Greater than** → Threshold `70` → Duration `5 minutes` → Action: **Increase count by 1**, cooldown `5 min`.
   - Add a second rule: CPU **Less than** `25` for `5 minutes` → **Decrease count by 1**, cooldown `5 min`.
6. **Management / Health**: enable **Application Health monitoring**, protocol HTTP, path `/api/health.php`, port 80.
7. **Advanced** tab → **Custom data**: paste the full contents of
   `infra/cloud-init-portal.yaml` (included in this project) into the box.
   **Before pasting**, edit two lines inside it:
   ```
   SetEnv DB_HOST "aabha-mysql.mysql.database.azure.com"   # your server name from step 4
   SetEnv DB_PASS "the-password-you-set-for-restaurant_app"
   ```
8. **Review + create** → **Create**. Wait for provisioning — cloud-init
   installs Apache/PHP and writes out the app files automatically on first
   boot (give it ~3-5 minutes after the VMSS itself finishes deploying).

---

## 7. Azure Bastion (admin access, no public SSH)

1. Search **"Bastion"** → **+ Create**.
2. RG `rg-aabha-dev`, name `aabha-bastion`, Region same.
3. Virtual network `aabha-vnet` → it should auto-detect `AzureBastionSubnet`.
4. Public IP: **Create new**, SKU Standard.
5. Tier: **Basic** is enough for this project.
6. **Review + create** → **Create**.

Once it's up: go to a VMSS instance → **Connect** → **Bastion** → sign in
with the SSH key you set in step 6. From there you can run the MySQL
commands from step 4, check `/var/log/cloud-init-output.log` if the site
isn't loading, etc.

---

## 8. Test it

1. Go to **Application Gateway → aabha-agw → Overview** and copy the
   **Frontend public IP address**.
2. Open it in a browser: `http://<that-ip>/`. You should see the Aabha site.
3. Fill in the reservation form and submit — you should get back a
   reference code, and a new row should appear in the `bookings` table.
4. If it fails: check **Application Gateway → Backend health** first
   (confirms the App Gateway can reach the VMSS instances on `/api/health.php`),
   then Bastion into an instance and check `/var/log/apache2/error.log`.

---

## 9. Cleaning up

Search **"Resource groups"** → `rg-aabha-dev` → **Delete resource group**.
This removes everything created above in one action (VNet, NSGs, NAT
Gateway, MySQL server, App Gateway, VMSS, Bastion) so you don't keep
paying for it.
