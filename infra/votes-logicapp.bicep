// ============================================================
// Audience Votes - Logic App (Consumption)
// ------------------------------------------------------------
// MS Form -> this Logic App -> AetherES Eventstream custom endpoint
//   -> Eventhouse "Votes" table -> Audience Votes RTI dashboard.
//
// Pattern credited to: https://github.com/liamhowlett/fabric-rti-livesurvey
//
// The workflow definition lives in votes-logicapp.workflow.json and is
// loaded at compile time. Form-specific values (form id, question ids)
// are passed as workflow parameters so nothing is hard-coded.
// ============================================================

@description('Azure region for the Logic App and its API connections.')
param location string = resourceGroup().location

@description('Name of the Logic App (Consumption) workflow.')
param logicAppName string = 'aether-votes-logicapp'

@description('Name of the Microsoft Forms API connection.')
param formsConnectionName string = 'aether-forms'

@description('Name of the Event Hubs API connection.')
param eventHubConnectionName string = 'aether-eventhub'

@description('Event Hub-compatible connection string from the AetherES Eventstream custom endpoint. Includes EntityPath=es_<guid>.')
@secure()
param eventHubConnectionString string

@description('Event Hub name (the EntityPath value parsed from the Eventstream connection string, e.g. es_<guid>).')
param eventHubName string

@description('Microsoft Forms form id (the long id from the form edit URL, not the /r/ short link).')
param formId string = ''

@description('Optional. The Forms question id that captures the Suspect vote. Bind in the designer after deploy if left blank.')
param suspectQuestionId string = ''

@description('Optional. The Forms question id that captures the Vote Section / voting round (e.g. "Final Vote").')
param voteSectionQuestionId string = ''

@description('Optional. The Forms question id that captures the voter Name. Falls back to the responder email if left blank.')
param nameQuestionId string = ''

var managedApiEventHubs = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'eventhubs')
var managedApiForms = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'microsoftforms')

resource eventHubConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: eventHubConnectionName
  location: location
  properties: {
    displayName: 'AetherES Event Hub'
    api: {
      id: managedApiEventHubs
    }
    parameterValues: {
      connectionString: eventHubConnectionString
    }
  }
}

// Microsoft Forms uses OAuth, so this connection deploys unauthenticated.
// A one-time "Authorize" click in the Azure portal is required after deploy.
resource formsConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: formsConnectionName
  location: location
  properties: {
    displayName: 'Microsoft Forms'
    api: {
      id: managedApiForms
    }
  }
}

resource votesWorkflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('votes-logicapp.workflow.json')
    parameters: {
      '$connections': {
        value: {
          microsoftforms: {
            connectionId: formsConnection.id
            connectionName: formsConnectionName
            id: managedApiForms
          }
          eventhubs: {
            connectionId: eventHubConnection.id
            connectionName: eventHubConnectionName
            id: managedApiEventHubs
          }
        }
      }
      formId: {
        value: formId
      }
      eventHubName: {
        value: eventHubName
      }
      suspectQuestionId: {
        value: suspectQuestionId
      }
      voteSectionQuestionId: {
        value: voteSectionQuestionId
      }
      nameQuestionId: {
        value: nameQuestionId
      }
    }
  }
}

output logicAppName string = votesWorkflow.name
output logicAppResourceId string = votesWorkflow.id
output formsConnectionName string = formsConnectionName
output formsConnectionResourceId string = formsConnection.id
