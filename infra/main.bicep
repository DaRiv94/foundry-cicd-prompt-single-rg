// One Foundry account and one project. Dev, test, and prod agents all live inside this
// single project (the lightweight topology), so this template is deployed once.
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param regionCode string = 'eus'
param workload string = 'pasingle'
param chatModelName string = 'gpt-5-nano'
param chatModelVersion string = '2025-08-07'
@minValue(1)
param chatCapacity int = 10

var accountName = 'msf-ais-${regionCode}-${workload}'
var projectName = 'prj-ais-${regionCode}-${workload}'
var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

resource account 'Microsoft.CognitiveServices/accounts@2026-05-01' = {
  name: accountName
  location: location
  tags: { workload: workload }
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true // keyless: Entra identities and role assignments only
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-05-01' = {
  parent: account
  name: projectName
  location: location
  tags: { workload: workload }
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Frankies Bakery support agents (dev, test, and prod side by side)'
  }
}

// The deployment is always called chat-model so the agent definition never changes.
resource chatModel 'Microsoft.CognitiveServices/accounts/deployments@2026-05-01' = {
  parent: account
  name: 'chat-model'
  sku: { name: 'GlobalStandard', capacity: chatCapacity }
  properties: {
    model: { format: 'OpenAI', name: chatModelName, version: chatModelVersion }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}

// Lets the project identity call the account's models (needed by evaluations).
resource projectFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, project.id, foundryUserRoleId)
  properties: {
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
  }
}

output accountName string = account.name
output projectName string = project.name
output projectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${project.name}'
