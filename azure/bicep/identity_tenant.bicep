// Microsoft Entra External ID (CIAM) tenant.
//
// This module is deployed SEPARATELY from main.bicep (see deploy.sh, opt-in via
// CREATE_TENANT=true). It is intentionally NOT wired into main.bicep because:
//   1. Creating a ciamDirectories resource requires a DELEGATED USER token —
//      a managed identity / service principal (app-only token) is rejected.
//   2. The external tenant has a different auth context and a different
//      lifecycle from the Functions/Storage/Cosmos stack.
//
// NOTE: The ciamDirectories resource type is preview-only
// (2023-05-17-preview). Suitable for test/eval; review before production use.
targetScope = 'resourceGroup'

@description('Name of the CIAM directory Azure resource (alphanumeric, max 26 chars).')
@minLength(1)
@maxLength(26)
param tenantResourceName string

@description('Display name of the external (CIAM) tenant.')
param tenantDisplayName string = 'Daily Cloud Photo External ID'

@description('Data residency location for the tenant.')
@allowed([
  'United States'
  'Europe'
  'Asia Pacific'
  'Australia'
])
param dataLocation string = 'United States'

@description('Country code for the tenant (e.g. US, JP). Must map to a valid data residency location.')
param countryCode string = 'US'

@description('SKU name for the CIAM (External ID) tenant. External ID uses "Base".')
@allowed([
  'Base'
])
param skuName string = 'Base'

resource ciamTenant 'Microsoft.AzureActiveDirectory/ciamDirectories@2023-05-17-preview' = {
  name: tenantResourceName
  location: dataLocation
  sku: {
    name: skuName
    tier: 'A0'
  }
  properties: {
    createTenantProperties: {
      countryCode: countryCode
      displayName: tenantDisplayName
    }
  }
}

@description('The directory (tenant) ID of the created external tenant.')
output tenantId string = ciamTenant.properties.tenantId

@description('The Azure resource name of the CIAM directory.')
output resourceName string = ciamTenant.name
