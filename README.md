# Minimal hub-spoke topology in Azure via Bicep

Minimal hub-spoke network in Azure, built with Bicep and Azure Verified Modules (AVM). One hub VNet with a Linux VM router and two spoke VNets peered to the hub. Traffic between the spokes is routed through the hub. Name resolution uses one central set of Private DNS zones: Private Link zones and the internal zone `hubspoke.internal`, where VMs register automatically. Every VNet is linked to every zone and uses Azure-provided DNS. Every subnet has its own network security group (NSG), with only the default rules for now. An Azure Bastion in the hub lets you sign in to any VM with your Microsoft Entra ID account, without SSH keys.

![Hub-spoke topology](diagram/hub-spoke-nsg-dns-bastion.png)

## Prerequisites

```powershell
winget install --exact --id Microsoft.AzureCLI
az bicep upgrade
```

The three subscriptions (connectivity, app1-dev, app2-dev) must already exist. Bicep does not create them.

## Deploy

**Before the first deployment, create the Entra ID groups for VM sign-in and put their object IDs in the param files** ([Sign in to a VM](#sign-in-to-a-vm), steps 1 and 2). The templates assign roles to those IDs, and a deployment fails with `PrincipalNotFound` if a group doesn't exist. Group membership can be changed at any time. If you leave an ID empty (`''`), that role assignment is skipped; you can set it and redeploy later.

**When you redeploy, the VMs must be running.** Azure can't change VM extensions (like the Entra ID login extension) on a deallocated VM, and the deployment fails with `Cannot modify extensions in the VM when the VM is not running`. Start the router (`az vm start -g rg-hub-shared -n vm-router-shared-swedencentral-001`) or the spoke's test VM first.

```powershell
ssh-keygen -t ed25519 -f "$HOME\.ssh\azure-hub-spoke-template-01" -C "azure-hub-spoke-template-01"
$env:ADMIN_SSH_PUBLIC_KEY = Get-Content "$HOME\.ssh\azure-hub-spoke-template-01.pub"

az login --tenant '<tenant-id>'

# Hub
az account set --subscription '<hub-subscription-id>'
az deployment sub create -n hub-shared -l swedencentral -f platform/connectivity/main.bicep -p platform/connectivity/params/shared.bicepparam

# Update subscriptionId in platform/hub.bicep, then deploy the spokes.

# Spoke app1
az account set --subscription '<app1-subscription-id>'
az deployment sub create -n spoke-app1-dev -l swedencentral -f landing-zones/main.bicep -p landing-zones/app1/dev.bicepparam

# Spoke app2
az account set --subscription '<app2-subscription-id>'
az deployment sub create -n spoke-app2-dev -l swedencentral -f landing-zones/main.bicep -p landing-zones/app2/dev.bicepparam
```

## Sign in to a VM

Signing in through Bastion with Microsoft Entra ID needs roles on these resources. Contributor and Owner don't include VM login, so even the person who deployed everything has to assign them.

| Resource | Role | Why |
|---|---|---|
| Each VM you sign in to | **Virtual Machine Administrator Login** (with `sudo`) or **Virtual Machine User Login** (without) | The VM's `AADSSHLoginForLinux` extension checks this role at sign-in |
| The same VM | **Reader** | Bastion and the portal read the VM |
| The VM's network interface (NIC) | **Reader** | Bastion reads the VM's private IP |
| The VM's VNet | **Reader** | Required when Bastion is in a peered VNet, so for every spoke VM. Not required, but harmless, for the router in the hub |
| The Bastion (`bas-hub-shared-swedencentral-001`) | **Reader** | Once, to use the Bastion |

The templates create these role assignments for Entra ID security groups. You only create the groups and manage who is in them:
- **Spoke resource group:** each landing zone assigns **Virtual Machine Administrator Login** and **Reader** to its own group (`vmAdminLoginGroupObjectId`, e.g. `sg-app1-dev-vm-admin-login`). In this repo the spoke resource group holds only the test VM, its NIC and its VNet, so this covers the first four rows and survives VM recreation.
- **Hub resource group:** the hub template does the same for hub (platform) admins on `rg-hub-shared`, with the same param name `vmAdminLoginGroupObjectId` (`sg-hub-shared-vm-admin-login`), for signing in to the router. Hub admins own the hub, so Reader on the whole resource group is fine. It also covers the Bastion, so this group doesn't need to be in `sg-hub-shared-bastion-users`.
- **Bastion:** the hub assigns **Reader on the Bastion resource only** to one group (`bastionUsersGroupObjectId`, `sg-hub-shared-bastion-users`). Each landing zone's group is added as a member of it, so the hub never needs to know about individual spokes. Reader on all of `rg-hub-shared` would show the whole hub to app teams. A separate resource group for Bastion isn't possible, because Azure requires the Bastion to be in its VNet's resource group.

Steps 1 and 2 come **before** the deployment, because the role assignments refer to the groups' object IDs.

1. **Create the groups once, and nest the app1 group into the Bastion users group.** Creating groups needs Entra permission to create groups; by default users have it unless the tenant restricts it. Adding people to the groups can also happen later, at any time.

   ```powershell
   az ad group create --display-name 'sg-hub-shared-bastion-users' --mail-nickname 'sg-hub-shared-bastion-users'
   az ad group create --display-name 'sg-hub-shared-vm-admin-login' --mail-nickname 'sg-hub-shared-vm-admin-login'
   az ad group create --display-name 'sg-app1-dev-vm-admin-login' --mail-nickname 'sg-app1-dev-vm-admin-login'
   $bastionUsersId = az ad group show --group 'sg-hub-shared-bastion-users' --query id -o tsv
   $hubLoginId     = az ad group show --group 'sg-hub-shared-vm-admin-login' --query id -o tsv
   $app1LoginId    = az ad group show --group 'sg-app1-dev-vm-admin-login' --query id -o tsv
   # app1's members can use the Bastion through nested membership (hub admins don't need it)
   az ad group member add --group 'sg-hub-shared-bastion-users' --member-id $app1LoginId
   # Who may sign in: add people to the login groups, not to the templates
   az ad group member add --group 'sg-app1-dev-vm-admin-login' --member-id (az ad signed-in-user show --query id -o tsv)
   az ad group member add --group 'sg-hub-shared-vm-admin-login' --member-id (az ad user show --id 'jane.doe@contoso.com' --query id -o tsv)
   $bastionUsersId; $hubLoginId; $app1LoginId   # copy these into the param files
   ```

2. **Put the object IDs in the param files.** In [platform/connectivity/params/shared.bicepparam](platform/connectivity/params/shared.bicepparam): `bastionUsersGroupObjectId` and `vmAdminLoginGroupObjectId` (hub admins). In [landing-zones/app1/dev.bicepparam](landing-zones/app1/dev.bicepparam): `vmAdminLoginGroupObjectId` (app1). An empty value means no role assignment.

3. **Deploy the hub, then the landing zone** (see [Deploy](#deploy)), or redeploy them if they already exist without the IDs. Creating role assignments needs **Role Based Access Control Administrator** (or Owner) on `rg-hub-shared` and on the spoke subscription. Contributor can't create them. Ideally use RBAC Administrator with a condition that limits it to the Reader and Virtual Machine Login roles.

4. **Connect.** In the Azure portal, open a VM, then select **Connect** → **Bastion**, set the authentication type to **Microsoft Entra ID**, and select **Connect**. In the session, `whoami` shows your Entra user name and `sudo -v` works.

Notes:
- Use one group per landing zone and environment, named after what it grants (`sg-<spoke>-<env>-vm-admin-login`). For app2, create `sg-app2-dev-vm-admin-login`, add it to `sg-hub-shared-bastion-users`, and set its object ID in `landing-zones/app2/dev.bicepparam`.
- To give someone access to the router, add them to `sg-hub-shared-vm-admin-login`. Keep that group small: the router is platform infrastructure. The assignments are on `rg-hub-shared`, so they survive recreating the router or the Bastion and also cover any VM added to the hub later.
- Check what the templates assigned: `az role assignment list --scope <resource group or Bastion resource ID> -o table`, or Access control (IAM) → Role assignments in the portal.
- Someone added to a group gets access after signing in again, because group membership is read from the sign-in token. To remove access, run `az ad group member remove`.
- Group names say which login role they grant: `…-vm-admin-login` for `Virtual Machine Administrator Login` (with `sudo`). For people who shouldn't get `sudo`, use a separate `…-vm-user-login` group with `Virtual Machine User Login`. The templates only assign the admin role today.
- Azure roles can't be assigned to Entra directory roles (such as Global Administrator), only to users, groups, service principals and managed identities, so access goes through the group.
- If the **Microsoft Entra ID** option doesn't show up in the portal, a role is missing or not applied yet, or the VM's `AADSSHLoginForLinux` extension isn't installed (`az vm extension list -g <rg> --vm-name <vm> -o table`). The extension must be named `AADSSHLoginForLinux`. An older `AADLogin` extension from a previous version of these templates works on the VM, but the portal doesn't recognize it. Delete it with `az vm extension delete -g <rg> --vm-name <vm> -n AADLogin` (VM running) and redeploy.

## Test connectivity

```powershell
az vm run-command invoke -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --command-id RunShellScript --scripts "ping -c 4 10.0.8.4; tracepath -n 10.0.8.4"
# Name resolution across spokes: expect 10.0.8.4
az vm run-command invoke -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --command-id RunShellScript --scripts "getent hosts vm-conntest-app2-dev-swedencentral-001.hubspoke.internal"
```

## Clean up

### Turn off Bastion only

Azure Bastion can't be stopped and costs about $140/month until it's deleted. Its public IP costs about $3.6/month too, even when it isn't attached to anything. To save both and keep everything else:

1. Set `deployBastion = false` in [platform/connectivity/params/shared.bicepparam](platform/connectivity/params/shared.bicepparam), so the next hub deployment doesn't recreate them.
2. Delete the Bastion, then its public IP. The order matters: a public IP that's still attached to the Bastion can't be deleted.

   ```powershell
   az network bastion delete -g rg-hub-shared -n bas-hub-shared-swedencentral-001 --subscription '<hub-subscription-id>'
   az network public-ip delete -g rg-hub-shared -n pip-bas-hub-shared-swedencentral-001 --subscription '<hub-subscription-id>'
   ```

The subnet and its NSG (both free) and the role assignments on the resource groups stay. The Reader assignment on the Bastion is deleted along with it. To turn Bastion back on, set `deployBastion = true` and redeploy the hub. That takes about 10 minutes and recreates the Bastion, its public IP (with a new address, which nothing depends on, because you connect through the portal) and the Reader assignment.

### Delete everything

Run each command in the subscription that contains the resource group.

```powershell
az group delete -n rg-spoke-app1-dev --yes
az group delete -n rg-spoke-app2-dev --yes
az group delete -n rg-hub-shared --yes
az group delete -n rg-dns-shared --yes
```
