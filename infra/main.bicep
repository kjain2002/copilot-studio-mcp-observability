targetScope = 'resourceGroup'

@description('Globally unique lowercase prefix; use a different deployment for each environment.')
@minLength(3)
@maxLength(10)
param namePrefix string
param location string = resourceGroup().location
@description('Power Platform environment GUID, not the Dataverse organization ID.')
param environmentId string
param dataverseUrl string
@allowed(['monthly', 'weekly', 'daily', 'near-live'])
param mode string = 'weekly'
@minValue(1)
param initialDays int = 7
@description('Must match the actual Dataverse retention policy. Monthly requires >= 40.')
@minValue(1)
param sourceRetentionDays int = 30
@minValue(1)
param overlapHours int = 48
@minValue(1)
param sliceHours int = 24
@minValue(1)
param maxTranscriptsPerSlice int = 10000
@description('Report retention in Blob Storage; does not change Dataverse retention.')
@minValue(1)
param reportRetentionDays int = 90
@description('Email distribution list for collector execution failures. Required for production.')
param alertEmail string

var suffix = uniqueString(resourceGroup().id, namePrefix)
var schedules = {
  monthly: '0 0 2 1 * *'
  weekly: '0 0 2 * * 1'
  daily: '0 0 2 * * *'
  'near-live': '0 */5 * * * *'
}

resource hostStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: '${namePrefix}h${suffix}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
  }
}
resource hostBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: hostStorage
  name: 'default'
}
resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: hostBlobService
  name: 'deployments'
  properties: { publicAccess: 'None' }
}
resource reportsStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: '${namePrefix}r${suffix}'
  location: location
  sku: { name: 'Standard_ZRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
  }
}
resource reportService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: reportsStorage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}
resource reports 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: reportService
  name: 'reports'
  properties: { publicAccess: 'None' }
}
resource retention 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: reportsStorage
  name: 'default'
  properties: {
    policy: {
      rules: [{
        name: 'expire-report-runs-not-checkpoints'
        enabled: true
        type: 'Lifecycle'
        definition: {
          filters: {
            blobTypes: ['blockBlob']
            prefixMatch: ['reports/environments/${environmentId}/runs/']
          }
          actions: {
            baseBlob: { delete: { daysAfterModificationGreaterThan: reportRetentionDays } }
          }
        }
      }]
    }
  }
}
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs-${suffix}'
  location: location
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}
resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-insights-${suffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
  }
}
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${namePrefix}-plan-${suffix}'
  location: location
  kind: 'functionapp'
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}
resource app 'Microsoft.Web/sites@2024-04-01' = {
  name: '${namePrefix}-collector-${suffix}'
  location: location
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${hostStorage.properties.primaryEndpoints.blob}${deploymentContainer.name}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      runtime: { name: 'python', version: '3.12' }
      scaleAndConcurrency: { maximumInstanceCount: 40, instanceMemoryMB: 2048 }
    }
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: hostStorage.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD' }
        { name: 'ENVIRONMENT_ID', value: environmentId }
        { name: 'DATAVERSE_URL', value: dataverseUrl }
        { name: 'REPORTS_ACCOUNT_URL', value: reportsStorage.properties.primaryEndpoints.blob }
        { name: 'REPORTS_CONTAINER', value: reports.name }
        { name: 'COLLECTION_MODE', value: mode }
        { name: 'COLLECTION_SCHEDULE', value: schedules[mode] }
        { name: 'INITIAL_DAYS', value: string(initialDays) }
        { name: 'SOURCE_RETENTION_DAYS', value: string(sourceRetentionDays) }
        { name: 'OVERLAP_HOURS', value: string(overlapHours) }
        { name: 'SLICE_HOURS', value: string(sliceHours) }
        { name: 'MAX_TRANSCRIPTS_PER_SLICE', value: string(maxTranscriptsPerSlice) }
      ]
    }
  }
}
resource hostBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hostStorage.id, app.id, 'host-blob')
  scope: hostStorage
  properties: {
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  }
}
resource hostQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hostStorage.id, app.id, 'host-queue')
  scope: hostStorage
  properties: {
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  }
}
resource reportsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(reports.id, app.id, 'reports')
  scope: reports
  properties: {
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}
resource monitoringRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insights.id, app.id, 'monitoring')
  scope: insights
  properties: {
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
}
resource alertGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${namePrefix}-operations'
  location: 'global'
  properties: {
    groupShortName: 'mcp-ops'
    enabled: true
    emailReceivers: [{ name: 'operations', emailAddress: alertEmail, useCommonAlertSchema: true }]
  }
}
resource failureAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${namePrefix}-collector-failures'
  location: 'global'
  properties: {
    description: 'Collector exceptions: inspect private runtime logs and the last committed checkpoint.'
    severity: 2
    enabled: true
    scopes: [insights.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [{
        name: 'exceptions'
        metricNamespace: 'microsoft.insights/components'
        metricName: 'exceptions/count'
        operator: 'GreaterThan'
        threshold: 0
        timeAggregation: 'Count'
        criterionType: 'StaticThresholdCriterion'
      }]
    }
    actions: [{ actionGroupId: alertGroup.id }]
    autoMitigate: true
  }
}

output functionAppName string = app.name
output managedIdentityObjectId string = app.identity.principalId
output reportsAccountName string = reportsStorage.name
output reportsContainer string = reports.name
output applicationInsightsName string = insights.name
