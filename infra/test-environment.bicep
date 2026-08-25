@description('Azure region for the isolated validation resources.')
param location string = resourceGroup().location

@description('Recovery Services vault used for the resource-group-scope test.')
param resourceGroupScopeVaultName string

@description('Recovery Services vault used for the subscription-scope test.')
param subscriptionScopeVaultName string

@description('Automation Account that hosts the remediation runbook.')
param automationAccountName string

@description('Name of the isolated Smart Tiering test policy in each vault.')
param backupPolicyName string = 'smart-tiering-remediation-test'

@description('Tiering mode for the disposable test policies. Keep the default for safe redeploys; use DoNotTier only to seed an isolated remediation test.')
@allowed([
  'TierRecommended'
  'DoNotTier'
])
param testPolicyTieringMode string = 'TierRecommended'

@description('Mark resources for retained portal inspection instead of as cleanup candidates.')
param retainForInspection bool = false

@description('Creation date applied to validation-resource tags.')
param createdOn string = utcNow('yyyy-MM-dd')

@description('UTC schedule fixture. Override with a suitable value when creating a new canary.')
param scheduleRunTime string = '2026-08-25T02:00:00Z'

var lifecycle = retainForInspection ? 'RetainForInspection' : 'CleanupCandidate'

var tags = {
  Purpose: retainForInspection ? 'SmartTieringLiveDemo' : 'SmartTieringControlPlaneValidation'
  CreatedBy: 'SmartTieringReferenceRepository'
  CreatedOn: createdOn
  Lifecycle: lifecycle
  DataClassification: 'NoBackupData'
}

var testPolicyProperties = {
  backupManagementType: 'AzureIaasVM'
  instantRpRetentionRangeInDays: 2
  schedulePolicy: {
    schedulePolicyType: 'SimpleSchedulePolicy'
    scheduleRunFrequency: 'Daily'
    scheduleRunTimes: [
      scheduleRunTime
    ]
  }
  retentionPolicy: {
    retentionPolicyType: 'LongTermRetentionPolicy'
    dailySchedule: {
      retentionTimes: [
        scheduleRunTime
      ]
      retentionDuration: {
        count: 30
        durationType: 'Days'
      }
    }
    weeklySchedule: {
      daysOfTheWeek: [
        'Sunday'
      ]
      retentionTimes: [
        scheduleRunTime
      ]
      retentionDuration: {
        count: 12
        durationType: 'Weeks'
      }
    }
    monthlySchedule: {
      retentionScheduleFormatType: 'Daily'
      retentionScheduleDaily: {
        daysOfTheMonth: [
          {
            date: 1
            isLast: false
          }
        ]
      }
      retentionTimes: [
        scheduleRunTime
      ]
      retentionDuration: {
        count: 12
        durationType: 'Months'
      }
    }
    yearlySchedule: {
      retentionScheduleFormatType: 'Daily'
      monthsOfYear: [
        'January'
      ]
      retentionScheduleDaily: {
        daysOfTheMonth: [
          {
            date: 1
            isLast: false
          }
        ]
      }
      retentionTimes: [
        scheduleRunTime
      ]
      retentionDuration: {
        count: 2
        durationType: 'Years'
      }
    }
  }
  tieringPolicy: {
    ArchivedRP: {
      tieringMode: testPolicyTieringMode
    }
  }
  timeZone: 'UTC'
}

resource automationAccount 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
  properties: {
    disableLocalAuth: true
    publicNetworkAccess: true
    sku: {
      name: 'Basic'
    }
  }
}

resource runtimeEnvironment 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  parent: automationAccount
  name: 'PowerShell74'
  location: location
  tags: {
    Purpose: tags.Purpose
    CreatedOn: tags.CreatedOn
    Lifecycle: tags.Lifecycle
  }
  properties: {
    description: 'PowerShell 7.4 runtime for Smart Tiering audit and enable-only remediation.'
    defaultPackages: {}
    runtime: {
      language: 'PowerShell'
      version: '7.4'
    }
  }
}

resource resourceGroupScopeVault 'Microsoft.RecoveryServices/vaults@2025-08-01' = {
  name: resourceGroupScopeVaultName
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

resource resourceGroupScopePolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2025-08-01' = {
  parent: resourceGroupScopeVault
  name: backupPolicyName
  location: location
  properties: testPolicyProperties
}

resource subscriptionScopeVault 'Microsoft.RecoveryServices/vaults@2025-08-01' = {
  name: subscriptionScopeVaultName
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

resource subscriptionScopePolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2025-08-01' = {
  parent: subscriptionScopeVault
  name: backupPolicyName
  location: location
  properties: testPolicyProperties
}

output automationAccountPrincipalId string = automationAccount.identity.principalId
output automationAccountId string = automationAccount.id
output runtimeEnvironmentName string = runtimeEnvironment.name
output resourceGroupScopeVaultId string = resourceGroupScopeVault.id
output subscriptionScopeVaultId string = subscriptionScopeVault.id
output backupPolicyName string = backupPolicyName
