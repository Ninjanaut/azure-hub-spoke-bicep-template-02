using '../main.bicep'

param addressPrefix = '10.0.0.0/22'
param tags = {
  workload: 'hub-spoke'
}
// Azure Bastion can't be stopped (about $140/month). To turn it off: set false, then delete it
// (see "Cleanup and cost" in CLAUDE.md). To turn it back on: set true and redeploy the hub.
param deployBastion = true
// Entra ID group with Reader on the Bastion; landing zone VM admin login groups are its members (see "Sign in to a VM" in CLAUDE.md).
// Empty: no role assignment. Object ID: az ad group show --group 'sg-hub-shared-bastion-users' --query id -o tsv
param bastionUsersGroupObjectId = ''
// Entra ID group of hub (platform) admins who may sign in to the router through Bastion. Empty: no role assignments.
// Object ID: az ad group show --group 'sg-hub-shared-vm-admin-login' --query id -o tsv
param vmAdminLoginGroupObjectId = ''
// Router VM SSH public key, read at deploy time so it stays out of the repo (see "SSH key" in CLAUDE.md).
// Create once:   ssh-keygen -t ed25519 -f "$HOME\.ssh\azure-hub-spoke-template-01" -C "azure-hub-spoke-template-01"
// Before deploy: $env:ADMIN_SSH_PUBLIC_KEY = Get-Content "$HOME\.ssh\azure-hub-spoke-template-01.pub"
param adminSshPublicKey = readEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY')
