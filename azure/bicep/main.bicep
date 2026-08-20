// Daily Cloud Photo — Azure backend (Entra External ID + Flex Consumption).
//
// Orchestrates: managed identity, storage, Cosmos DB, IAM role assignments and
// the Function App (Flex Consumption). Authentication is delegated to Microsoft
// Entra External ID via native authentication, so no JWT secret is provisioned.
targetScope = 'resourceGroup'

@description('Base name for all resources (lowercase, no special characters).')
@minLength(3)
@maxLength(20)
param appName string = 'dailycloudphoto'

@description('Azure region for all resources.')
param location string = resourceGroup().location

// ── Microsoft Entra External ID (native authentication) ──
@description('External tenant subdomain, e.g. "contoso" for contoso.onmicrosoft.com.')
param entraTenantSubdomain string = ''

@description('External tenant (directory) GUID.')
param entraTenantId string = ''

@description('Application (client) ID of the native-auth public client app.')
param entraClientId string = ''

@description('OAuth scopes requested when acquiring tokens.')
param entraScopes string = 'openid offline_access'

// ── Feature flags / behaviour (mirrors the app settings) ──
@allowed([ 'true', 'false' ])
param requireEmail string = 'true'
@allowed([ 'true', 'false' ])
param requirePhone string = 'false'
@allowed([ 'true', 'false' ])
param enableShareUrl string = 'true'
@allowed([ 'true', 'false' ])
param enableShareDownloadUrl string = 'true'
@allowed([ 'true', 'false' ])
param enableLabelSharing string = 'true'
param shareUploadUrlExpiryHours int = 24
param shareDownloadUrlExpiryHours int = 72

// ── Flex Consumption sizing ──
param maximumInstanceCount int = 100
@allowed([ 512, 2048, 4096 ])
param instanceMemoryMB int = 2048
param pythonVersion string = '3.11'

// ── Derived names ──
var uniqueSuffix = uniqueString(resourceGroup().id, appName)
var shortSuffix = take(uniqueSuffix, 8)
var storageAccountName = take('${appName}${uniqueSuffix}', 24)
var functionAppName = '${appName}-func-${shortSuffix}'
var planName = '${appName}-plan-${shortSuffix}'
var cosmosAccountName = '${appName}-db-${shortSuffix}'
var appInsightsName = '${appName}-ai-${shortSuffix}'
var logAnalyticsName = '${appName}-logs-${shortSuffix}'
var identityName = '${appName}-id-${shortSuffix}'
var cosmosDatabase = 'dailycloudphoto'
var photosContainer = 'photos'
var usersContainer = 'users'
var deploymentContainer = 'deploymentpackage'

// ── Modules ──
module identity 'identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    identityName: identityName
  }
}

module storage 'storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: storageAccountName
    photosContainerName: photosContainer
    deploymentContainerName: deploymentContainer
  }
}

module cosmos 'cosmos.bicep' = {
  name: 'cosmos'
  params: {
    location: location
    cosmosAccountName: cosmosAccountName
    databaseName: cosmosDatabase
    usersContainerName: usersContainer
    photosContainerName: photosContainer
  }
}

module iam 'iam.bicep' = {
  name: 'iam'
  params: {
    storageAccountName: storage.outputs.name
    principalId: identity.outputs.principalId
  }
}

// Reference deployed data resources to build connection strings for the app
// logic (SAS generation + Cosmos SDK). Platform storage uses managed identity.
resource storageAccountRef 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storage.outputs.name
}

resource cosmosAccountRef 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: cosmos.outputs.name
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.outputs.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccountRef.listKeys().keys[0].value}'
var cosmosConnectionString = cosmosAccountRef.listConnectionStrings().connectionStrings[0].connectionString

var appConfigSettings = {
  // App logic data-plane connections.
  COSMOS_CONNECTION: cosmosConnectionString
  COSMOS_DATABASE: cosmosDatabase
  STORAGE_CONNECTION: storageConnectionString
  STORAGE_CONTAINER: photosContainer
  // Microsoft Entra External ID (native authentication).
  ENTRA_TENANT_SUBDOMAIN: entraTenantSubdomain
  ENTRA_TENANT_ID: entraTenantId
  ENTRA_CLIENT_ID: entraClientId
  ENTRA_SCOPES: entraScopes
  // Feature flags / behaviour.
  REQUIRE_EMAIL: requireEmail
  REQUIRE_PHONE: requirePhone
  ENABLE_SHARE_URL: enableShareUrl
  ENABLE_SHARE_DOWNLOAD_URL: enableShareDownloadUrl
  ENABLE_LABEL_SHARING: enableLabelSharing
  SHARE_UPLOAD_URL_EXPIRY_HOURS: string(shareUploadUrlExpiryHours)
  SHARE_DOWNLOAD_URL_EXPIRY_HOURS: string(shareDownloadUrlExpiryHours)
  FUNCTION_APP_URL: 'https://${functionAppName}.azurewebsites.net'
}

module functions 'functions.bicep' = {
  name: 'functions'
  params: {
    location: location
    functionAppName: functionAppName
    planName: planName
    appInsightsName: appInsightsName
    logAnalyticsName: logAnalyticsName
    managedIdentityId: identity.outputs.id
    managedIdentityClientId: identity.outputs.clientId
    storageAccountName: storage.outputs.name
    storageBlobEndpoint: storage.outputs.blobEndpoint
    deploymentContainerName: storage.outputs.deploymentContainerName
    pythonVersion: pythonVersion
    maximumInstanceCount: maximumInstanceCount
    instanceMemoryMB: instanceMemoryMB
    appConfigSettings: appConfigSettings
  }
  dependsOn: [
    iam
  ]
}

// ── Outputs ──
output functionAppName string = functions.outputs.functionAppName
output apiEndpoint string = 'https://${functions.outputs.defaultHostName}/v1'
output storageAccountName string = storage.outputs.name
output cosmosAccountName string = cosmos.outputs.name
output managedIdentityClientId string = identity.outputs.clientId
