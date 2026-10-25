using '../main.bicep'

import { hub } from '../../platform/hub.bicep'

param spokeName = 'app1'
param environment = 'dev'
param addressPrefix = '10.0.4.0/22'
param hubVnetResourceId = hub.vnetResourceId
param routerIpAddress = hub.routerIpAddress
param privateLinkDnsZoneResourceIds = hub.privateLinkDnsZoneResourceIds
param internalDnsZoneResourceId = hub.internalDnsZoneResourceId
// Entra ID group whose members may sign in to this spoke's VMs through Bastion. Empty: no role assignments.
// Object ID: az ad group show --group 'sg-app1-dev-vm-admin-login' --query id -o tsv
param vmAdminLoginGroupObjectId = ''
param tags = {
  workload: 'app1'
}

// Connectivity test VM. Its SSH public key is read at deploy time so it stays out of the repo.
// Create once:   ssh-keygen -t ed25519 -f "$HOME\.ssh\azure-hub-spoke-template-01" -C "azure-hub-spoke-template-01"
// Before deploy: $env:ADMIN_SSH_PUBLIC_KEY = Get-Content "$HOME\.ssh\azure-hub-spoke-template-01.pub"
param deployTestVm = true
param adminSshPublicKey = readEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY')
