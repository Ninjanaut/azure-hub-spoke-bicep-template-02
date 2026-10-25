# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A minimal Azure hub-and-spoke network written in Bicep. It's meant as material for a blog article and as base infrastructure for later proofs of concept, so keep it simple. It intentionally has no VPN gateway and no firewall. The goals are routing between spokes and central Private DNS. Every subnet has its own NSG with only the default rules, ready for rules later. One Azure Bastion (Basic) in the hub lets people sign in to every VM, in the hub and in all spokes, with their Microsoft Entra ID account instead of SSH keys.

The layout follows the enterprise platform / landing-zone split, scaled down to one repo. Resources come from Azure Verified Modules (AVM).

Spoke-to-spoke traffic goes through a small Linux router VM in the hub's `snet-router` (static IP `10.0.0.4`). VNet peering isn't transitive, so each spoke's workload subnet has a route table with one route, `10.0.0.0/16` → `VirtualAppliance` → `10.0.0.4`. Longest prefix wins: the spoke's own VNet and the hub keep their more specific system and peering routes, so only traffic to other spokes goes to the router. The router reaches every spoke directly through the hub's peering routes, so return traffic needs no extra routes. Every peering sets `allowForwardedTraffic: true`. The router forwards packets because IP forwarding is on at both levels: on the NIC (`enableIPForwarding`) and in the OS (`net.ipv4.ip_forward=1` from `platform/connectivity/router-cloud-init.yaml`).

DNS uses central Private DNS zones with **no resolver**: there's no on-premises network or VPN, so nothing outside the VNets needs to resolve them. One shared set of zones lives in `rg-dns-shared` in the connectivity subscription, and **every VNet is linked to every zone**. All VNets use Azure-provided DNS (`168.63.129.16`), which only answers from zones linked to the VM's own VNet; peering doesn't share links. The hub template links the hub. Each landing zone links its own VNet in the DNS resource group, the same way it creates the hub → spoke peering. Adding a spoke adds only that spoke's links; the hub and other spokes aren't touched. There are two kinds of zones:
- **Private Link zones** (`privatelink.blob…`, `.file…`, `vaultcore`, `database…`) are listed once, in `privateLinkDnsZones` in `platform/hub.bicep`. The hub template creates them, and landing zones link to them with `registrationEnabled: false`. A private endpoint in any spoke registers its record in the central zone through its DNS zone group. To add a zone type, edit the list before you deploy a private endpoint of that type, then redeploy the hub and every landing zone (the only change that touches every spoke).
- **The internal zone `hubspoke.internal`** has auto-registration. The hub link registers the router, and each landing zone links its own VNet with `registrationEnabled: true`, so VMs resolve each other as `<vm-name>.hubspoke.internal` across spokes.

Limits: 1,000 VNet links per zone, of which at most 100 can have auto-registration. With P2S VPN or on-premises later, add a DNS Private Resolver with an inbound endpoint in the hub (clients can't reach `168.63.129.16`); the zone links stay as they are.

## Layout

```
platform/
  connectivity/main.bicep             # hub + DNS resource groups, hub VNet + subnet NSGs, router VM, Bastion, Private DNS zones linked to the hub (subscription scope)
  connectivity/router-cloud-init.yaml # enables IP forwarding in the router OS
  connectivity/params/shared.bicepparam
  hub.bicep                           # exported hub details and the Private Link zone list (not deployed)
landing-zones/
  main.bicep                          # one spoke resource group + route table + NSG + VNet + both peering directions + Private DNS zone links + optional test VM (subscription scope)
  <spokeName>/<environment>.bicepparam
```

## Commands

All commands run in PowerShell 7 (`pwsh`) with the Azure CLI. Building and linting need no login.

```powershell
# Install Azure CLI and Bicep. The -e flag is short for --exact. It tells winget to match the package query exactly.
winget install -e --id Microsoft.AzureCLI 
az bicep upgrade

# Linting is static analysis of your code. The linter reads your .bicep file without deploying anything and flags things that are valid syntax but are likely mistakes, bad practice, or security risks.       
az bicep lint --file landing-zones/main.bicep  

# Compiles a Bicep file into a standard ARM JSON file.
az bicep build --file landing-zones/main.bicep 
# Param files that deploy a VM need $env:ADMIN_SSH_PUBLIC_KEY set (see "SSH key" below)
az bicep build-params --file landing-zones/app1/dev.bicepparam
az bicep build-params --file platform/connectivity/params/shared.bicepparam
```

### Sign in

```powershell
az login --tenant '<tenant-id>'                         # opens a browser; add --use-device-code on a machine without one
az account list -o table                                # subscriptions you can see
az account set --subscription '<hub-subscription-id>'   # select before each step below
az account show -o table                                # check the active subscription
```

`az deployment sub create` targets the active subscription, so switch with `az account set` between the hub and spoke steps. The hub → spoke peering uses the hub subscription from `hubVnetResourceId` regardless of the active one.

### SSH key (router and test VMs)

A Linux VM needs a password or an SSH key, and these templates only accept a key. You create the key pair yourself, once, as a dedicated key used only for this PoC. Azure doesn't generate it.

```powershell
# Once: create the key pair (OpenSSH is built into Windows 11). Run it in PowerShell, not cmd, WSL or Git Bash,
# and answer both passphrase prompts (empty is fine) or no files are written.
ssh-keygen -t ed25519 -f "$HOME\.ssh\azure-hub-spoke-template-01" -C "azure-hub-spoke-template-01"
#   C:\Users\<you>\.ssh\azure-hub-spoke-template-01      private key: stays on your machine, never share or commit it
#   C:\Users\<you>\.ssh\azure-hub-spoke-template-01.pub  public key: the one that goes to Azure

# Before each deployment, in the same PowerShell window
$env:ADMIN_SSH_PUBLIC_KEY = Get-Content "$HOME\.ssh\azure-hub-spoke-template-01.pub"
$env:ADMIN_SSH_PUBLIC_KEY                               # check: prints one line, ssh-ed25519 AAAA... azure-hub-spoke-template-01

# Optional: set it permanently for your user (applies to newly opened windows)
[Environment]::SetEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY', (Get-Content "$HOME\.ssh\azure-hub-spoke-template-01.pub"), 'User')
```

- The variable holds the key's **text**, not the path to the file. A variable set with `$env:` only lasts until you close that PowerShell window.
- The hub param file and every landing-zone param file with `deployTestVm = true` read the variable with `readEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY')`. If it isn't set, `az deployment` and `az bicep build-params` fail with `BCP427` (VS Code shows the same error until it's restarted from a window where the variable is set). A landing zone without a test VM doesn't need it.
- Azure writes the key into `/home/azureuser/.ssh/authorized_keys` **inside the VM**. That's what `publicKeys.path` in the templates means: a Linux path, not a Windows one. No key file is stored in the repo.
- Azure requires a key (or password) on every Linux VM at creation, so it stays, but only as a **break-glass** credential. Day-to-day login is with Microsoft Entra ID through Bastion (see below), and `az vm run-command invoke` doesn't use SSH either.
- One key for all VMs is fine for this PoC. In production, keep it in a Key Vault and never hand it out.

### Deploy

Order: **(0) Entra ID groups → (1) hub → (2) landing zones.** The templates assign roles to group object IDs (`bastionUsersGroupObjectId`, `vmAdminLoginGroupObjectId`), so create the groups and set the IDs in the param files first (see "Sign in to a VM" below). A missing group fails the deployment with `PrincipalNotFound`. An empty ID skips that assignment; set it and redeploy later. Group membership (people, and nesting into `sg-hub-shared-bastion-users`) can change at any time and doesn't affect the deployment.

**Start deallocated VMs before redeploying.** Azure can't add or change VM extensions (`AADSSHLoginForLinux`) on a stopped VM, so a redeploy fails with `OperationNotAllowed: Cannot modify extensions in the VM when the VM is not running`. Run `az vm start -g rg-hub-shared -n vm-router-shared-swedencentral-001` (or the spoke's test VM) first, then deploy again.

```powershell
$env:ADMIN_SSH_PUBLIC_KEY = Get-Content "$HOME\.ssh\azure-hub-spoke-template-01.pub"   # every new PowerShell window; see "SSH key" above
# 1) Hub, once (active subscription: hub); the template creates rg-hub-shared itself
az account set --subscription '<hub-subscription-id>'
az deployment sub create -n hub-shared -l swedencentral -f platform/connectivity/main.bicep -p platform/connectivity/params/shared.bicepparam
# 2) Landing zone, one at a time (active subscription: spoke); the template creates rg-spoke-<spokeName>-<environment>, the route table,
#    the spoke VNet, peering both ways and, with deployTestVm = true, the test VM
az account set --subscription '<spoke-subscription-id>'
az deployment sub create -n spoke-app1-dev -l swedencentral -f landing-zones/main.bicep -p landing-zones/app1/dev.bicepparam
# Dry run: `az deployment sub what-if` with the same arguments
```

### Sign in to a VM (Bastion + Microsoft Entra ID)

Every VM has a system-assigned managed identity and the `AADSSHLoginForLinux` extension, so the Bastion in the hub can sign you in with your Entra ID account (MFA and Conditional Access apply). Contributor and Owner **don't** include VM login. Sign-in needs these roles (Microsoft Learn, "Configure Microsoft Entra ID authentication – Azure Bastion"), and the templates assign them to Entra ID groups:

| Resource | Role | Why |
|---|---|---|
| Each VM you sign in to | Virtual Machine Administrator Login (`sudo`) or Virtual Machine User Login | The VM's `AADSSHLoginForLinux` extension checks this role at sign-in |
| The same VM | Reader | Bastion and the portal read the VM |
| The VM's NIC | Reader | Bastion reads the VM's private IP |
| The VM's VNet | Reader | Required when Bastion is in a peered VNet (every spoke VM); not required, but harmless, for the router in the hub |
| The Bastion (`bas-hub-shared-…`) | Reader | Once, to use the Bastion |

- **Spoke resource group (landing zone template):** the `rg` module's `roleAssignments` give **Virtual Machine Administrator Login** and **Reader** to `vmAdminLoginGroupObjectId`, e.g. `sg-app1-dev-vm-admin-login`. The spoke resource group holds only the test VM, NIC and VNet, so this covers the first four rows and survives VM recreation.
- **Hub resource group (hub template):** the same pattern and the same param name. The hub `rg` module gives **Virtual Machine Administrator Login** and **Reader** on `rg-hub-shared` to `vmAdminLoginGroupObjectId` (`sg-hub-shared-vm-admin-login`, hub/platform admins) for the router. Hub admins own the hub, so resource group scope is fine. Reader there also covers the Bastion, so this group isn't nested into `sg-hub-shared-bastion-users`, and the assignments survive recreating the router or the Bastion.
- **Bastion (hub template):** the `bastion` module's `roleAssignments` give **Reader on the Bastion resource only** to `bastionUsersGroupObjectId` (`sg-hub-shared-bastion-users`). Landing zone groups are **members** of it (nested groups), so the hub stays spoke-agnostic and the assignment is recreated with the Bastion (`deployBastion`). Reader on all of `rg-hub-shared` would expose the hub VNet, router and NSGs. A separate resource group for Bastion isn't possible, because Azure requires the Bastion to be in its VNet's resource group.
- An empty object ID skips the assignments, so Contributor can still deploy. With IDs set, the deployment identity needs **Role Based Access Control Administrator** (or Owner) on `rg-hub-shared` and on the spoke subscription; ideally constrained by a condition to Reader and the Virtual Machine Login roles.
- Groups and their membership stay outside Bicep. Azure roles can't be assigned to Entra directory roles, only to users, groups, service principals and managed identities. Create the groups once and put their object IDs in the param files **before deploying** (a missing group fails with `PrincipalNotFound`):

```powershell
az ad group create --display-name 'sg-hub-shared-bastion-users' --mail-nickname 'sg-hub-shared-bastion-users'
az ad group create --display-name 'sg-hub-shared-vm-admin-login' --mail-nickname 'sg-hub-shared-vm-admin-login'
az ad group create --display-name 'sg-app1-dev-vm-admin-login' --mail-nickname 'sg-app1-dev-vm-admin-login'
$bastionUsersId = az ad group show --group 'sg-hub-shared-bastion-users' --query id -o tsv    # -> bastionUsersGroupObjectId (shared.bicepparam)
$hubLoginId     = az ad group show --group 'sg-hub-shared-vm-admin-login' --query id -o tsv   # -> vmAdminLoginGroupObjectId (shared.bicepparam)
$app1LoginId    = az ad group show --group 'sg-app1-dev-vm-admin-login' --query id -o tsv     # -> vmAdminLoginGroupObjectId (app1/dev.bicepparam)
az ad group member add --group 'sg-hub-shared-bastion-users' --member-id $app1LoginId         # nested: app1 members can use the Bastion
az ad group member add --group 'sg-app1-dev-vm-admin-login' --member-id (az ad signed-in-user show --query id -o tsv)   # people go here
az ad group member add --group 'sg-hub-shared-vm-admin-login' --member-id (az ad user show --id <upn> --query id -o tsv)   # hub admins
# After deploying: check what the templates assigned
az role assignment list --scope "/subscriptions/<app1-subscription-id>/resourceGroups/rg-spoke-app1-dev" -o table
```

- One group per landing zone and environment, named after what it grants (`sg-<spoke>-<env>-vm-admin-login`). A new spoke: create its group, add it to `sg-hub-shared-bastion-users`, and set `vmAdminLoginGroupObjectId` in its param file.
- Router access: add hub admins to `sg-hub-shared-vm-admin-login`, and keep that group small, because the router is platform infrastructure.
- New group members get access after signing in again, because membership is read from the token. Remove access with `az ad group member remove`.
- Group names say which login role they grant: `…-vm-admin-login` → Virtual Machine Administrator Login (`sudo`). A no-`sudo` group would be `…-vm-user-login` with Virtual Machine User Login; the templates only assign the admin role today.
- Connect: in the portal, open the VM, then **Connect** → **Bastion** → Authentication type **Microsoft Entra ID** → **Connect**. The session opens in the browser, and `whoami` shows your UPN.
- If the Entra ID option is missing, the extension isn't installed (or is the old `AADLogin` one, see the VMs bullet under Architecture) or a role is missing. Role assignments can take a few minutes to apply.
- Basic SKU means portal sessions only. `az network bastion ssh --auth-type AAD` from your own terminal needs the Standard SKU.

### Test spoke-to-spoke routing

```powershell
# The test VMs come from the landing-zone deployments above (deployTestVm = true in the param file), in the spoke resource group.
# The testVmPrivateIpAddress output gives each VM's IP (the first VM in a subnet gets .4: app1 10.0.4.4, app2 10.0.8.4)

# Routes the platform programmed: expect 10.0.0.0/16 -> VirtualAppliance 10.0.0.4
az network nic show-effective-route-table -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001-nic-01 -o table
# Real traffic: tracepath should show 10.0.0.4 as the hop before 10.0.8.4
az vm run-command invoke -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --command-id RunShellScript --scripts "ping -c 4 10.0.8.4; tracepath -n 10.0.8.4"
# Proof on the router (hub subscription, second terminal while the ping runs)
az vm run-command invoke -g rg-hub-shared -n vm-router-shared-swedencentral-001 --command-id RunShellScript --scripts "timeout 20 tcpdump -ni eth0 icmp"
# Negative test: turn forwarding off and the ping fails; turn it back on with =1
az vm run-command invoke -g rg-hub-shared -n vm-router-shared-swedencentral-001 --command-id RunShellScript --scripts "sysctl -w net.ipv4.ip_forward=0"

# Entra ID login extension on a VM: expect AADSSHLoginForLinux, Succeeded
az vm extension list -g rg-spoke-app1-dev --vm-name vm-conntest-app1-dev-swedencentral-001 -o table

# NSG on the subnet: expect the default rules of nsg-app1-dev-swedencentral-001 (and none on the NIC)
az network nic list-effective-nsg -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001-nic-01 -o json

# DNS. Cross-spoke name resolution through app1's zone link and app2's auto-registered record: expect 10.0.8.4
az vm run-command invoke -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --command-id RunShellScript --scripts "getent hosts vm-conntest-app2-dev-swedencentral-001.hubspoke.internal"
# Private Link zone answered from the linked central zone: SOA from azureprivatedns.net
az vm run-command invoke -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --command-id RunShellScript --scripts "dig +short SOA privatelink.blob.core.windows.net"
# Auto-registered records (hub subscription): router + test VMs
az network private-dns record-set a list -g rg-dns-shared -z hubspoke.internal -o table

# Cleanup and cost: delete the test VMs (NIC and disk are deleted with them) and deallocate the router when idle.
# Also set deployTestVm = false in the param files, or the next landing-zone deployment recreates them.
az vm delete -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --yes
az vm delete -g rg-spoke-app2-dev -n vm-conntest-app2-dev-swedencentral-001 --yes
az vm deallocate -g rg-hub-shared -n vm-router-shared-swedencentral-001
# Start it again (az vm start) before the next hub deployment; extensions can't be changed on a stopped VM.
# Bastion (Basic, about $140/month) can't be deallocated or stopped; it's billed until deleted.
# Turn it off: set deployBastion = false in platform/connectivity/params/shared.bicepparam (so the next hub
# deployment doesn't recreate it), then delete the Bastion and its public IP (about $3.6/month even unattached),
# in this order: an attached public IP can't be deleted (hub subscription):
az network bastion delete -g rg-hub-shared -n bas-hub-shared-swedencentral-001 --subscription '<hub-subscription-id>'
az network public-ip delete -g rg-hub-shared -n pip-bas-hub-shared-swedencentral-001 --subscription '<hub-subscription-id>'
# Kept: AzureBastionSubnet and its NSG (free), and the role assignments on the resource groups.
# The Reader assignment on the Bastion itself is deleted with it.
# Turn it back on: set deployBastion = true and redeploy the hub (about 10 minutes); that recreates the Bastion,
# its public IP (new address; nothing depends on it, you connect through the portal) and the Reader assignment.
```

### Required permissions (Azure RBAC)

| Step | Scope | Minimum built-in role |
|---|---|---|
| Hub | hub subscription (the template creates `rg-hub-shared` and `rg-dns-shared`) | Contributor |
| Landing zone | spoke subscription (the template creates `rg-spoke-…`) | Contributor |
| Landing zone | `rg-hub-shared` (hub → spoke peering, `peer/action` on the hub VNet, nested deployment) | Network Contributor |
| Landing zone | `rg-dns-shared` (spoke VNet links on every zone, nested deployments) | Private DNS Zone Contributor |
| Hub, with `bastionUsersGroupObjectId` or `vmAdminLoginGroupObjectId` set | `rg-hub-shared` (Reader on the Bastion for the Bastion users group; login role + Reader on the resource group for hub admins) | Role Based Access Control Administrator, ideally limited by a condition to Reader and the Virtual Machine Login roles |
| Landing zone, with `vmAdminLoginGroupObjectId` set | spoke subscription (login role + Reader on the spoke resource group) | Role Based Access Control Administrator, ideally limited to Reader and the Virtual Machine Login roles |
| VM sign-in (people, through Entra ID groups) | assigned by the templates; see "Sign in to a VM" | Virtual Machine Administrator Login (or User Login) + Reader |

- Both templates need the subscription scope because they create resource groups.
- `what-if` needs the same roles as the deployment it previews.
- The `Microsoft.Network` resource provider must be registered in each subscription. Contributor at subscription scope registers it automatically on first deployment; otherwise run `az provider register -n Microsoft.Network`.
- Hub and spoke subscriptions must be in the same Microsoft Entra tenant for a single-identity deployment; cross-tenant peering isn't supported by these templates.

## Architecture

- **Two templates, both subscription-scoped.** The platform team owns the connectivity subscription and the landing-zone networking. `platform/connectivity/main.bicep` creates `rg-hub-shared` and the hub VNet in it, and future platform resource groups and resources go there too. `landing-zones/main.bicep` creates one spoke resource group, the route table and the spoke VNet in it, and peers it with the hub. With `deployTestVm = true` it also adds a throwaway test VM (`vm-conntest-…`) to the workload subnet. There is one template and one param file per spoke environment, with no separate test template. In both, `location` defaults to the deployment location (`-l`), and the VNet module is scoped to the resource group by name with an explicit `dependsOn` on the resource group module. Adding a spoke never touches the hub template.
- **AVM.** The templates use `br/public:avm/res/network/virtual-network`, `…/resources/resource-group`, `…/network/route-table`, `…/network/network-security-group`, `…/network/bastion-host`, `…/compute/virtual-machine` and its child module `…/compute/virtual-machine/extension` (the Entra ID login extension), `…/network/private-dns-zone` and its child module `…/network/private-dns-zone/virtual-network-link` (the landing zone adds its links without redeploying the zones), each pinned to an exact version. Bump a module's version in every file that uses it.
- **VMs are as cheap as possible.** All VMs run Ubuntu 24.04, but the sizes differ because Azure offers different sizes per subscription, even in the same region.
  - **Router:** `Standard_B1s` (BS family, 1 vCPU, 1 GiB). The Connectivity subscription had no quota for the newer burstable families (Bsv2, Basv2, Bpsv2) but did for BS. B1s doesn't support accelerated networking, which AVM enables by default, so the router NIC sets `enableAcceleratedNetworking: false`.
  - **Spoke test VMs:** `Standard_D2pls_v6` (Dplsv6 family, 2 vCPU, 4 GiB, Arm64 Azure Cobalt 100, about $48/month) with accelerated networking on. Because it's Arm64, the image SKU is `server-arm64` (`testVmImageSku`); change both params together for an x64 size. The spoke subscriptions aren't offered the older sizes (B1s, B2s, A1_v2, F1s) in Sweden Central and have no Basv2/Bsv2 quota, but they have default Dplsv6 quota (10 vCPU). Check with `az vm list-skus -l swedencentral --size <size> --subscription <sub>` and `az vm list-usage`.
  - The VMs have a 30 GB `Standard_LRS` disk and no public IP. You sign in through Bastion with Entra ID, or manage them with `az vm run-command invoke` (or the serial console; the router has managed boot diagnostics turned on). Every VM sets `managedIdentities: { systemAssigned: true }` and gets the Entra ID login extension from a separate `…/compute/virtual-machine/extension` module (`routerAadLogin`, `testVmAadLogin`), named and typed exactly `AADSSHLoginForLinux`. AVM's built-in `extensionAadJoinConfig` isn't used: it hardcodes the type `AADSSHLoginforLinux` (lowercase f) and the name `AADLogin`, which work on the VM, but the portal's Bastion page then says the extension isn't installed and offers no Entra ID sign-in. A VM can't have two extensions from the same handler, so a VM that still has `AADLogin` needs `az vm extension delete -n AADLogin` once before the next deployment. The router IP is defined in two places: `routerIpAddress` in `platform/connectivity/main.bicep` (`cidrHost(routerSubnetPrefix, 3)`) and `platform/hub.bicep`. Keep both in sync. The same goes for `dnsResourceGroupName` and `internalDnsZoneName`. The Private Link zone list exists only in `platform/hub.bicep`, and the hub template imports it. `enableTelemetry` is set to `false`.
- **One NSG per subnet, default rules only.** Each NSG is attached at subnet level (CAF/ALZ practice; ALZ enforces it with the `Deny-Subnet-Without-Nsg` policy). NICs have no NSG. The defaults allow all current traffic, because the `VirtualNetwork` service tag covers the VNet, peered VNets and UDR prefixes:
  - **Router subnet:** both spokes are peered with the hub, so forwarded spoke-to-spoke packets match `AllowVnetInBound` / `AllowVnetOutBound`.
  - **Spoke subnet:** other spokes aren't peered with it, but the `10.0.0.0/16` UDR puts them in the tag, so traffic from them is allowed. Without that route it would hit `DenyAllInBound`.
  - **Not filtered or still allowed:** Azure DNS (`168.63.129.16`) is never filtered, and `AllowInternetOutBound` covers the VM agent, `run-command` and the Entra login extension. SSH from Bastion comes from the peered hub, so `AllowVnetInBound` allows it.
  - **Exception: `nsg-bastion-…`** on `AzureBastionSubnet` has rules, because an NSG there must contain all the rules Microsoft lists (inbound 443 from Internet, GatewayManager and AzureLoadBalancer; outbound 22/3389 to VirtualNetwork, 443 to AzureCloud, 80 to Internet; 8080/5701 VirtualNetwork both ways). Without them, Bastion loses connectivity and platform updates.
  - **Adding rules:** add them as `securityRules` on the NSG module in the owning template. AVM replaces all custom rules on every deployment, so rules added in the portal are lost.
- **One Bastion for everything.** `bas-hub-shared-…` (Basic SKU) sits in the hub's `AzureBastionSubnet` (a name Azure requires, so not CAF; /26 minimum, `10.0.1.0/26`). It reaches every spoke VM over the hub peering, so spokes need no Bastion of their own. Basic is the cheapest SKU that supports peered VNets and Entra ID SSH in the portal; Developer only reaches its own VNet, and the native client needs Standard. AVM creates the Standard/Static public IP `pip-bas-…`, which is the only public IP in the setup.
- **Peering lives in the landing zone.** The spoke's AVM call has one `peerings` entry with `remotePeeringEnabled: true`. AVM creates spoke → hub in the spoke resource group, and hub → spoke in a nested deployment scoped to the hub's subscription and resource group (both parsed from `hubVnetResourceId`, so the hub can be in another subscription). The identity running a landing-zone deployment needs network write access to the hub resource group as well. Attaching a VNet that wasn't created by `landing-zones/main.bicep` would need its own peering deployment.
- **Hub details come from one place.** `platform/hub.bicep` exports a `hub` object (subscription ID, resource group, VNet name and resource ID, router IP, DNS resource group, internal zone ID, and the Private Link zone names and IDs). Landing-zone param files `import { hub }` and pass `hub.vnetResourceId`. The subscription ID is a placeholder to fill in. The resource group and VNet names must match what `platform/connectivity/main.bicep` builds.
- **Each VNet template owns its VNet's subnets.** Add subnets only in the owning template, never through the portal or a PoC template. AVM deploys subnets as separate child resources, not inline in the VNet, so check with `what-if` before redeploying over a VNet that has subnets added elsewhere.
- **Naming follows the Cloud Adoption Framework (CAF)**: `<type>-<workload>-<environment>-<region>-<###>`.
  - Spokes have a required `environment` (`prod`, `dev`, `test`, `qa` or `stage`), e.g. `vnet-app1-dev-swedencentral-001`, `snet-app1-dev-swedencentral-001` and `nsg-app1-dev-swedencentral-001` (the hub's are `nsg-router-shared-…` and `nsg-bastion-shared-…`, after their subnets; the Bastion is `bas-hub-shared-…` with public IP `pip-bas-hub-shared-…`). The environment is also added as a tag.
  - The hub's environment is fixed to `shared` (`vnet-hub-shared-swedencentral-001`, `snet-router-shared-…`, resource group `rg-hub-shared`) because both prod and nonprod spokes connect to it. CAF's environment list doesn't include `shared`; this is a deliberate extension so that every VNet follows the same pattern. Spokes can't use `shared`.
  - The region is the full `location` value, not an abbreviation, and `instance` defaults to `001`.
  - CAF has no format for Private DNS VNet links, so they're `link-<VNet name without vnet->`, e.g. `link-app1-dev-swedencentral-001` (the same name on every zone). Zone names are fixed by Azure (Private Link) or are a param (`hubspoke.internal`).
  - CAF defines no format for peerings, so they mirror its VPN connection format: `peer-<local>-to-<remote>`, with the `vnet-` prefix removed from both names (e.g. `peer-hub-shared-swedencentral-001-to-app1-dev-swedencentral-001`). The landing zone's module deployment name is cut to 64 characters with `take()`.
  - Resource groups have no region in their name. Each template creates its own: `rg-hub-shared` and `rg-spoke-<spokeName>-<environment>`, both overridable with the `resourceGroupName` param. Top-level deployment names follow the same pattern without `rg-` (`hub-shared`, `spoke-app1-dev`) and must be unique per subscription. Default subnets are the first /24 of the address space, computed with `cidrSubnet`. Each environment of a landing zone differs only by its `.bicepparam` file.
- Address plan: hub `10.0.0.0/22` (`10.0.0.0/24` router, `10.0.1.0/26` AzureBastionSubnet, the rest free, e.g. for a future DNS resolver or gateway subnet), spokes consecutive /22s after it (`10.0.4.0/22`, `10.0.8.0/22`, …; the third octet is a multiple of 4). Nothing checks for overlap, so the param files have to keep spokes from colliding.
- Run landing-zone deployments one at a time. Parallel runs all modify the hub VNet's peerings and can fail with `AnotherOperationInProgress`.

## Next steps (not implemented)

Management groups and policy (including the ALZ `Deploy-Private-DNS-Zones` DeployIfNotExists policy that attaches private endpoints to the central zones, and `Deny-Subnet-Without-Nsg`), NSG rules beyond the defaults, Bastion Standard for native-client SSH from a local terminal, PIM eligible (just-in-time) VM login assignments instead of permanent ones, deployment stacks so manually added role assignments are removed, VNet flow logs with Traffic Analytics (NSG flow logs are retired), a DNS Private Resolver (inbound endpoint for P2S VPN clients, outbound endpoint plus forwarding ruleset for on-premises DNS) once there's a VPN or on-premises network, pipelines with workload-identity (OIDC) service connections and `what-if` on pull requests, deployment stacks with deny settings so app teams can't remove the platform's peerings, subscription vending (`avm/ptn/lz/sub-vending`), and the Azure Landing Zones Bicep accelerator as a full reference.
