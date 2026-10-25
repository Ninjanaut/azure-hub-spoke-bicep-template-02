/*
Shared hub details: the only place landing zones learn where the hub is.
Not deployed. Landing-zone param files import it:
  import { hub } from '../../platform/hub.bicep'
Set subscriptionId to the hub subscription, and keep resourceGroupName and vnetName in sync with platform/connectivity/main.bicep.
*/

var subscriptionId = '00000000-0000-0000-0000-000000000000'
var resourceGroupName = 'rg-hub-shared'
var vnetName = 'vnet-hub-shared-swedencentral-001'
// Router VM's static IP; must match routerIpAddress in platform/connectivity/main.bicep
var routerIpAddress = '10.0.0.4'
// DNS: keep in sync with dnsResourceGroupName and internalDnsZoneName in platform/connectivity/main.bicep
var dnsResourceGroupName = 'rg-dns-shared'
var internalDnsZoneName = 'hubspoke.internal'
var privateDnsZoneIdPrefix = '/subscriptions/${subscriptionId}/resourceGroups/${dnsResourceGroupName}/providers/Microsoft.Network/privateDnsZones'
// Private Link zones: the only list. The hub creates them and every landing zone links its VNET to them.
// Adding a zone means redeploying the hub, then every landing zone.
// Zone names are fixed by Azure (public cloud), not endpoints, so the hardcoded-URL rule doesn't apply
#disable-diagnostics no-hardcoded-env-urls
var privateLinkDnsZones = [
  'privatelink.blob.core.windows.net'
  'privatelink.file.core.windows.net'
  'privatelink.vaultcore.azure.net'
  'privatelink.database.windows.net'
]
#restore-diagnostics no-hardcoded-env-urls

@export()
@description('Hub VNET location for landing zones')
var hub = {
  subscriptionId: subscriptionId
  resourceGroupName: resourceGroupName
  vnetName: vnetName
  vnetResourceId: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName}/providers/Microsoft.Network/virtualNetworks/${vnetName}'
  routerIpAddress: routerIpAddress
  dnsResourceGroupName: dnsResourceGroupName
  internalDnsZoneName: internalDnsZoneName
  internalDnsZoneResourceId: '${privateDnsZoneIdPrefix}/${internalDnsZoneName}'
  privateLinkDnsZones: privateLinkDnsZones
  privateLinkDnsZoneResourceIds: map(privateLinkDnsZones, zone => '${privateDnsZoneIdPrefix}/${zone}')
}
