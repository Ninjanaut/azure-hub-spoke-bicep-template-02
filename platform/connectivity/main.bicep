/*
Connectivity platform: owns the connectivity subscription. Deploy once, before any landing zone.
  az deployment sub create -n hub-shared -l swedencentral -f platform/connectivity/main.bicep -p platform/connectivity/params/shared.bicepparam
Creates its own resource groups; add further platform resource groups and modules here the same way.
Landing zones find the hub through platform/hub.bicep; keep it in sync with the names built here.
DNS: the Private DNS zones live in rg-dns-shared. Every VNET is linked to every zone and uses Azure-provided DNS;
this template links the hub, and each landing zone links its own VNET. No resolver (no on-premises or VPN).
*/

targetScope = 'subscription'

import { hub } from '../hub.bicep'

@description('Location for all hub resources')
param location string = deployment().location

@description('Hub resource group. Must match resourceGroupName in platform/hub.bicep.')
param resourceGroupName string = 'rg-hub-shared'

@description('Instance number used in resource names (CAF <###> component)')
param instance string = '001'

@description('Hub VNET address space')
param addressPrefix string = '10.0.0.0/22'

@description('Subnet reserved for the Linux router that will route spoke-to-spoke traffic')
param routerSubnetPrefix string = cidrSubnet(addressPrefix, 24, 0)

@description('Static private IP of the router VM (first usable address of the router subnet). Must match routerIpAddress in platform/hub.bicep.')
param routerIpAddress string = cidrHost(routerSubnetPrefix, 3)

@description('Private DNS zones resource group. Must match dnsResourceGroupName in platform/hub.bicep.')
param dnsResourceGroupName string = 'rg-dns-shared'

@description('Internal zone for VM names. Hub and spoke VNETs auto-register their VMs in it. Must match internalDnsZoneName in platform/hub.bicep.')
param internalDnsZoneName string = 'hubspoke.internal'

@description('AzureBastionSubnet prefix (/26 minimum). Default: the first /26 after the router /24.')
param bastionSubnetPrefix string = cidrSubnet(addressPrefix, 26, 4)

@description('Deploy Azure Bastion. It can\'t be stopped; set false and delete it and its public IP to save cost (see README, Turn off Bastion only). The subnet and NSG stay.')
param deployBastion bool = true

@description('Object ID of the Entra ID group that gets Reader on the Bastion (e.g. sg-hub-shared-bastion-users). Landing zones\' VM admin login groups become members of it. Empty: no role assignment, and Contributor is enough to deploy.')
param bastionUsersGroupObjectId string = ''

@description('Object ID of the Entra ID group of hub (platform) admins who may sign in to the hub VMs, i.e. the router, through Bastion (e.g. sg-hub-shared-vm-admin-login). Empty: no role assignments, and Contributor is enough to deploy.')
param vmAdminLoginGroupObjectId string = ''

@description('Router VM size. B1s (1 vCPU, 1 GiB, BS family) is enough for packet forwarding and the BS family usually has default quota; deallocate the VM when not in use.')
param routerVmSize string = 'Standard_B1s'

@description('Admin user on the router VM')
param adminUsername string = 'azureuser'

@description('SSH public key for the router VM admin user (from $env:ADMIN_SSH_PUBLIC_KEY via the params file)')
@secure()
param adminSshPublicKey string

@description('Tags applied to all hub resources')
param tags object = {}

// CAF naming: <type>-<workload>-<environment>-<region>-<###>
// Fixed environment: the hub is shared platform infrastructure for prod and non-prod spokes
var environment = 'shared'
var vnetName = 'vnet-hub-${environment}-${location}-${instance}'
var routerVmName = 'vm-router-${environment}-${location}-${instance}'
var routerNsgName = 'nsg-router-${environment}-${location}-${instance}'
var bastionName = 'bas-hub-${environment}-${location}-${instance}'
var bastionNsgName = 'nsg-bastion-${environment}-${location}-${instance}'
// Private Link zones for private endpoints. The list lives in platform/hub.bicep because landing zones link to the same zones.
var privateLinkDnsZones = hub.privateLinkDnsZones
// CAF has no VNET link format; link-<VNET name without vnet->
var hubLinkName = 'link-hub-${environment}-${location}-${instance}'

// -------------------- HUB RESOURCE GROUP (AVM) --------------------
// VM sign-in through Bastion with Entra ID for hub admins: the login role and Reader on the whole hub resource group
// (router VM, NIC, hub VNet, Bastion), the same pattern as the spoke resource groups. Hub admins own the hub, so
// resource group scope is fine, needs no nesting into the Bastion users group, and survives VM or Bastion recreation.
// Assigning roles needs Role Based Access Control Administrator (or Owner) on the hub subscription or rg-hub-shared.
module rg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'rg-hub-${environment}'
  params: {
    name: resourceGroupName
    location: location
    tags: union(tags, { environment: environment })
    roleAssignments: empty(vmAdminLoginGroupObjectId)
      ? []
      : [
          {
            // Built-in role GUID: AVM maps only a few role names (Owner, Contributor, Reader, ...), not this one
            roleDefinitionIdOrName: '1c0163c0-47e6-4577-8991-ea5c82e286e4' // Virtual Machine Administrator Login
            principalId: vmAdminLoginGroupObjectId
            principalType: 'Group'
            description: 'Bastion Entra ID sign-in to hub VMs (router)'
          }
          {
            roleDefinitionIdOrName: 'Reader'
            principalId: vmAdminLoginGroupObjectId
            principalType: 'Group'
            description: 'Bastion Entra ID sign-in to hub VMs (VM, NIC, VNet, Bastion)'
          }
        ]
    enableTelemetry: false
  }
}

// -------------------- DNS RESOURCE GROUP (AVM) --------------------
// Separate from the hub so DNS zones get their own RBAC and policy scope
module dnsRg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'rg-dns-${environment}'
  params: {
    name: dnsResourceGroupName
    location: location
    tags: union(tags, { environment: environment })
    enableTelemetry: false
  }
}

// -------------------- ROUTER SUBNET NSG (AVM) --------------------
// Default rules only. Forwarded spoke-to-spoke traffic is allowed by AllowVnetInBound/OutBound,
// because both spokes are peered with the hub and so are in its VirtualNetwork service tag.
// Add rules here as securityRules; they replace all custom rules on each deployment.
module routerNsg 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: routerNsgName
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: routerNsgName
    location: location
    tags: union(tags, { environment: environment })
    enableTelemetry: false
  }
}

// -------------------- BASTION SUBNET NSG (AVM) --------------------
// Unlike the other NSGs, this one needs rules: an NSG on AzureBastionSubnet must contain all rules from
// https://learn.microsoft.com/azure/bastion/bastion-nsg, or Bastion loses connectivity and platform updates.
module bastionNsg 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: bastionNsgName
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: bastionNsgName
    location: location
    tags: union(tags, { environment: environment })
    securityRules: [
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 140
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: {
          priority: 150
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionCommunication'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowHttpOutbound'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
        }
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- HUB VNET (AVM) --------------------
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet-hub-${environment}-${location}-${instance}'
  // Scoped by name, so the dependency on the resource group has to be explicit
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: vnetName
    location: location
    tags: union(tags, { environment: environment })
    addressPrefixes: [
      addressPrefix
    ]
    subnets: [
      {
        name: 'snet-router-${environment}-${location}-${instance}'
        addressPrefix: routerSubnetPrefix
        networkSecurityGroupResourceId: routerNsg.outputs.resourceId
      }
      {
        // Name required by Azure Bastion (not CAF)
        name: 'AzureBastionSubnet'
        addressPrefix: bastionSubnetPrefix
        networkSecurityGroupResourceId: bastionNsg.outputs.resourceId
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- BASTION (AVM) --------------------
// One Bastion for the hub and every peered spoke. Basic is the cheapest SKU that reaches peered VNETs
// and supports Microsoft Entra ID SSH in the portal; the native client (az network bastion ssh) needs Standard.
// Must be in the VNET's resource group. AVM creates the Standard/Static public IP.
// Optional (deployBastion): false doesn't delete an existing Bastion (incremental deployment); delete it with az network bastion delete.
module bastion 'br/public:avm/res/network/bastion-host:0.8.2' = if (deployBastion) {
  name: bastionName
  scope: resourceGroup(resourceGroupName)
  params: {
    name: bastionName
    location: location
    tags: union(tags, { environment: environment })
    virtualNetworkResourceId: vnet.outputs.resourceId
    skuName: 'Basic'
    publicIPAddressObject: {
      name: 'pip-${bastionName}'
    }
    // Reader on the Bastion, needed for Entra ID sign-in. One spoke-agnostic group: landing zones add their
    // VM admin login groups as members (nested groups), so adding a spoke never touches this template, and the
    // assignment comes back whenever the Bastion is recreated. Needs RBAC Administrator (or Owner) on rg-hub-shared.
    roleAssignments: empty(bastionUsersGroupObjectId)
      ? []
      : [
          {
            roleDefinitionIdOrName: 'Reader'
            principalId: bastionUsersGroupObjectId
            principalType: 'Group'
            description: 'Use the hub Bastion for Entra ID sign-in (members: landing zone VM admin login groups)'
          }
        ]
    enableTelemetry: false
  }
}

// -------------------- PRIVATE DNS ZONES (AVM) --------------------
// Resolution needs a link on each VNET: Azure DNS (168.63.129.16) only answers from zones linked to the
// VM's own VNET, and peering doesn't share links. This links the hub; landing zones link themselves.
// Private Link zones: private endpoints in any spoke register their records here (DNS zone group)
module privateLinkZones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [
  for zone in privateLinkDnsZones: {
    name: take('pdnsz-${zone}', 64)
    scope: resourceGroup(dnsResourceGroupName)
    dependsOn: [
      dnsRg
    ]
    params: {
      name: zone
      tags: union(tags, { environment: environment })
      virtualNetworkLinks: [
        {
          name: hubLinkName
          virtualNetworkResourceId: vnet.outputs.resourceId
          registrationEnabled: false
        }
      ]
      enableTelemetry: false
    }
  }
]

// Internal zone for VM names. Each landing zone links its VNET with auto-registration.
module internalZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: take('pdnsz-${internalDnsZoneName}', 64)
  scope: resourceGroup(dnsResourceGroupName)
  dependsOn: [
    dnsRg
  ]
  params: {
    name: internalDnsZoneName
    tags: union(tags, { environment: environment })
    virtualNetworkLinks: [
      {
        name: hubLinkName
        virtualNetworkResourceId: vnet.outputs.resourceId
        // Registers the router VM
        registrationEnabled: true
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- ROUTER VM (AVM) --------------------
// Forwards spoke-to-spoke traffic. Spoke route tables send other spokes' prefixes here.
// Forwarding is enabled on the NIC (enableIPForwarding) and in the OS (cloud-init).
// No public IP; sign in through Bastion with Entra ID, or use `az vm run-command invoke` or the serial console.
module router 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: routerVmName
  scope: resourceGroup(resourceGroupName)
  params: {
    name: routerVmName
    location: location
    tags: union(tags, { environment: environment })
    // Microsoft Entra ID SSH login needs a system-assigned identity; the extension is the routerAadLogin module below
    managedIdentities: {
      systemAssigned: true
    }
    vmSize: routerVmSize
    availabilityZone: -1
    osType: 'Linux'
    imageReference: {
      publisher: 'Canonical'
      offer: 'ubuntu-24_04-lts'
      sku: 'server'
      version: 'latest'
    }
    osDisk: {
      diskSizeGB: 30
      caching: 'ReadWrite'
      deleteOption: 'Delete'
      managedDisk: {
        storageAccountType: 'Standard_LRS'
      }
    }
    adminUsername: adminUsername
    disablePasswordAuthentication: true
    publicKeys: [
      {
        keyData: adminSshPublicKey
        path: '/home/${adminUsername}/.ssh/authorized_keys'
      }
    ]
    customData: loadTextContent('router-cloud-init.yaml')
    // Managed boot diagnostics, needed for the serial console
    bootDiagnostics: true
    nicConfigurations: [
      {
        nicSuffix: '-nic-01'
        enableIPForwarding: true
        // AVM enables it by default; B1s doesn't support accelerated networking
        enableAcceleratedNetworking: false
        deleteOption: 'Delete'
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: vnet.outputs.subnetResourceIds[0]
            privateIPAllocationMethod: 'Static'
            privateIPAddress: routerIpAddress
          }
        ]
      }
    ]
    enableTelemetry: false
  }
}

// Microsoft Entra ID SSH login extension, deployed separately instead of AVM's extensionAadJoinConfig: that one
// hardcodes the type 'AADSSHLoginforLinux' (lowercase f) and names it 'AADLogin'. It works on the VM, but the
// portal's Bastion page doesn't recognize it and doesn't offer Entra ID sign-in. Name and type here match what
// the portal and az vm extension set create. Changing extensions needs the VM running (az vm start).
module routerAadLogin 'br/public:avm/res/compute/virtual-machine/extension:0.1.0' = {
  name: take('${routerVmName}-aadsshlogin', 64)
  scope: resourceGroup(resourceGroupName)
  params: {
    virtualMachineName: router.outputs.name
    name: 'AADSSHLoginForLinux'
    location: location
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADSSHLoginForLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: false
    tags: union(tags, { environment: environment })
    enableTelemetry: false
  }
}

// Values needed by landing zones
output resourceGroupName string = rg.outputs.name
output vnetId string = vnet.outputs.resourceId
output vnetName string = vnet.outputs.name
output routerIpAddress string = routerIpAddress
output routerVmName string = router.outputs.name
output routerNsgName string = routerNsg.outputs.name
output bastionName string = deployBastion ? bastion!.outputs.name : ''
output dnsResourceGroupName string = dnsRg.outputs.name
output internalDnsZoneResourceId string = internalZone.outputs.resourceId
