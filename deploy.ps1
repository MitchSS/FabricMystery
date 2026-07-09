<#
.SYNOPSIS
    Deploys the "Ghost in the Aether" murder mystery to a Microsoft Fabric workspace.

.DESCRIPTION
    Orchestrates creation of all Fabric items in dependency order using the Fabric REST API.
    Reads local definition files, injects dynamic IDs, base64-encodes payloads, and deploys.

.PARAMETER WorkspaceName
    Target Fabric workspace name. Created if it does not exist.

.PARAMETER CapacityId
    Fabric capacity ID to assign to a newly created workspace. Required only for new workspaces.

.EXAMPLE
    .\deploy.ps1 -WorkspaceName "Fabric Mystery UG"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$WorkspaceName = "Fabric Mystery UG",

    [Parameter(Mandatory = $false)]
    [string]$CapacityId = ""
)

$ErrorActionPreference = "Stop"
$FabricApi = "https://api.fabric.microsoft.com/v1"
$FabricResource = "https://api.fabric.microsoft.com"
$ScriptRoot = $PSScriptRoot

# ============================================================
# Helper Functions
# ============================================================

function Invoke-FabricApi {
    param(
        [string]$Method,
        [string]$Url,
        [object]$Body = $null
    )

    $args = @("rest", "--method", $Method, "--resource", $FabricResource, "--url", $Url)

    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        $args += @("--body", $json)
        $args += @("--headers", "Content-Type=application/json")
    }

    $result = az @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "API call failed: $Method $Url`n$result"
    }

    if ($result) {
        return $result | ConvertFrom-Json
    }
    return $null
}

function Get-Base64File {
    param([string]$FilePath)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    return [Convert]::ToBase64String($bytes)
}

function Get-Base64String {
    param([string]$Content)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    return [Convert]::ToBase64String($bytes)
}

function Replace-Placeholders {
    param(
        [string]$Content,
        [hashtable]$Tokens
    )
    foreach ($key in $Tokens.Keys) {
        $Content = $Content -replace [regex]::Escape("{{$key}}"), $Tokens[$key]
    }
    return $Content
}

function Wait-ForJob {
    param(
        [string]$WorkspaceId,
        [string]$ItemId,
        [string]$JobInstanceId,
        [int]$TimeoutSeconds = 600
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $pollUrl = "$FabricApi/workspaces/$WorkspaceId/items/$ItemId/jobs/instances/$JobInstanceId"

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $status = Invoke-FabricApi -Method "GET" -Url $pollUrl
        Write-Host "  Job status: $($status.status)"

        if ($status.status -in @("Completed", "Failed", "Cancelled")) {
            if ($status.status -ne "Completed") {
                throw "Job $JobInstanceId finished with status: $($status.status)"
            }
            return $status
        }
    }
    throw "Job $JobInstanceId timed out after $TimeoutSeconds seconds"
}

function Deploy-Item {
    param(
        [string]$WorkspaceId,
        [string]$DisplayName,
        [string]$Type,
        [string]$Format,
        [array]$Parts
    )

    $body = @{
        displayName = $DisplayName
        type        = $Type
        definition  = @{
            format = $Format
            parts  = $Parts
        }
    }

    $result = Invoke-FabricApi -Method "POST" -Url "$FabricApi/workspaces/$WorkspaceId/items" -Body $body
    Write-Host "  Created: $DisplayName ($Type) -> $($result.id)"
    return $result
}

function Deploy-Report {
    param(
        [string]$WorkspaceId,
        [string]$ReportFolder,
        [string]$DisplayName,
        [string]$SemanticModelId
    )

    # Collect every file under the report folder. The local ".platform" file is a
    # git-integration artifact and is not part of a REST definition payload.
    $parts = @()
    $files = Get-ChildItem -Path $ReportFolder -Recurse -File | Where-Object { $_.Name -ne ".platform" }

    foreach ($file in $files) {
        $relPath = $file.FullName.Substring($ReportFolder.Length).TrimStart("\", "/") -replace "\\", "/"

        if ($relPath -eq "definition.pbir") {
            # Locally the report binds to the model by relative path (byPath), which the
            # service cannot resolve. Rebind to the freshly deployed model via a live
            # connection (byConnection) keyed on the semantic model's item ID.
            $pbir = Get-Content $file.FullName -Raw | ConvertFrom-Json
            $pbir.datasetReference = @{
                byConnection = @{
                    connectionString          = $null
                    pbiServiceModelId         = $null
                    pbiModelVirtualServerName = "sobe_wowvirtualserver"
                    pbiModelDatabaseName      = $SemanticModelId
                    name                      = "EntityDataSource"
                    connectionType            = "pbiServiceXmlaStyleLive"
                }
            }
            $payload = Get-Base64String ($pbir | ConvertTo-Json -Depth 20)
        }
        else {
            $payload = Get-Base64File $file.FullName
        }

        $parts += @{ path = $relPath; payload = $payload; payloadType = "InlineBase64" }
    }

    return Deploy-Item -WorkspaceId $WorkspaceId -DisplayName $DisplayName -Type "Report" -Format "PBIR" -Parts $parts
}

# ============================================================
# Main Deployment Flow
# ============================================================

Write-Host "============================================================"
Write-Host " Ghost in the Aether — Deployment"
Write-Host "============================================================"
Write-Host ""

# --- Step 1: Resolve or Create Workspace ---
Write-Host "[1/14] Resolving workspace: $WorkspaceName"

$workspaces = Invoke-FabricApi -Method "GET" -Url "$FabricApi/workspaces?`$filter=displayName eq '$WorkspaceName'"
$workspace = $workspaces.value | Where-Object { $_.displayName -eq $WorkspaceName } | Select-Object -First 1

if ($workspace) {
    $WS_ID = $workspace.id
    Write-Host "  Found existing workspace: $WS_ID"
} else {
    $wsBody = @{ displayName = $WorkspaceName }
    if ($CapacityId) { $wsBody.capacityId = $CapacityId }
    $workspace = Invoke-FabricApi -Method "POST" -Url "$FabricApi/workspaces" -Body $wsBody
    $WS_ID = $workspace.id
    Write-Host "  Created workspace: $WS_ID"
}

# --- Step 2: Create Eventhouse ---
Write-Host "[2/14] Creating Eventhouse + KQL Database"

$ehResult = Deploy-Item -WorkspaceId $WS_ID -DisplayName "AetherEH" -Type "Eventhouse" -Format "eventhouse" -Parts @(
    @{ path = "EventhouseProperties.json"; payload = (Get-Base64String '{}'); payloadType = "InlineBase64" }
)
$EH_ID = $ehResult.id

# Get the child KQL Database
Start-Sleep -Seconds 5
$items = Invoke-FabricApi -Method "GET" -Url "$FabricApi/workspaces/$WS_ID/items?type=KQLDatabase"
$kqlDb = $items.value | Where-Object { $_.displayName -eq "AetherEH" } | Select-Object -First 1
$KQL_DB_ID = $kqlDb.id
Write-Host "  KQL Database ID: $KQL_DB_ID"

# Get cluster URI from KQL DB properties
$kqlDbDetail = Invoke-FabricApi -Method "GET" -Url "$FabricApi/workspaces/$WS_ID/kqlDatabases/$KQL_DB_ID"
$CLUSTER_URI = $kqlDbDetail.properties.queryServiceUri
Write-Host "  Cluster URI: $CLUSTER_URI"

# --- Step 3: Create Lakehouse ---
Write-Host "[3/14] Creating Lakehouse"

$lhResult = Deploy-Item -WorkspaceId $WS_ID -DisplayName "AetherLH" -Type "Lakehouse" -Format "lakehouse" -Parts @(
    @{ path = "lakehouse.metadata.json"; payload = (Get-Base64String '{"properties":{}}'); payloadType = "InlineBase64" }
)
$LH_ID = $lhResult.id
Write-Host "  Lakehouse ID: $LH_ID"

# --- Step 4: Deploy KQL Schema ---
Write-Host "[4/14] Deploying KQL Schema"

$schemaPath = Join-Path $ScriptRoot "Aether\AetherEH.Eventhouse\.children\AetherEH.KQLDatabase\DatabaseSchema.kql"
$schemaContent = Get-Content $schemaPath -Raw

# Execute each .create-merge command against the KQL database
$commands = $schemaContent -split '(?=\.create-merge)' | Where-Object { $_.Trim() -ne "" -and $_ -match '\.create-merge' }
foreach ($cmd in $commands) {
    $cmdBody = @{ csl = $cmd.Trim(); db = "AetherEH" }
    Invoke-FabricApi -Method "POST" -Url "$CLUSTER_URI/v1/rest/mgmt" -Body $cmdBody
    Write-Host "  Executed: $($cmd.Substring(0, [Math]::Min(60, $cmd.Length)))..."
}

# --- Step 5: Create Shortcuts ---
Write-Host "[5/14] Creating Shortcuts (Eventhouse -> Lakehouse)"

$tokens = @{
    "WORKSPACE_ID"          = $WS_ID
    "EVENTHOUSE_ITEM_ID"    = $EH_ID
    "EVENTHOUSE_ARTIFACT_ID" = $KQL_DB_ID
    "LAKEHOUSE_ARTIFACT_ID" = $LH_ID
    "EVENTHOUSE_CLUSTER_URI" = $CLUSTER_URI
    "WORKSPACE_NAME"        = $WorkspaceName
}

$shortcutsPath = Join-Path $ScriptRoot "Aether\AetherLH.Lakehouse\shortcuts.metadata.json"
$shortcutsContent = Get-Content $shortcutsPath -Raw
$shortcutsContent = Replace-Placeholders -Content $shortcutsContent -Tokens $tokens
$shortcuts = $shortcutsContent | ConvertFrom-Json

foreach ($sc in $shortcuts.shortcuts) {
    $scBody = @{
        path   = $sc.path
        name   = $sc.name
        target = $sc.target
    }
    Invoke-FabricApi -Method "POST" -Url "$FabricApi/workspaces/$WS_ID/items/$LH_ID/shortcuts" -Body $scBody
    Write-Host "  Shortcut: $($sc.name)"
}

# --- Step 6: Deploy + Run Populate Notebook ---
Write-Host "[6/14] Deploying Populate Lakehouse Notebook"

$popNbPath = Join-Path $ScriptRoot "Aether\Populate Lakehouse.Notebook\notebook.ipynb"
$popNbContent = Get-Content $popNbPath -Raw
# Inject lakehouse ID into notebook metadata
$popNbContent = $popNbContent -replace '"id": ""', "`"id`": `"$LH_ID`""

$popNb = Deploy-Item -WorkspaceId $WS_ID -DisplayName "Populate Lakehouse" -Type "Notebook" -Format "ipynb" -Parts @(
    @{ path = "notebook.ipynb"; payload = (Get-Base64String $popNbContent); payloadType = "InlineBase64" }
)

Write-Host "  Running Populate Lakehouse notebook..."
$jobResult = Invoke-FabricApi -Method "POST" -Url "$FabricApi/workspaces/$WS_ID/items/$($popNb.id)/jobs/instances?jobType=RunNotebook" -Body @{}
$jobId = $jobResult.id
Wait-ForJob -WorkspaceId $WS_ID -ItemId $popNb.id -JobInstanceId $jobId

# --- Step 7: Deploy Semantic Model ---
Write-Host "[7/14] Deploying Semantic Model"

$smDir = Join-Path $ScriptRoot "Aether\AetherSM.SemanticModel\definition"
$smParts = @()

# Collect all TMDL files
$tmdlFiles = @("database.tmdl", "expressions.tmdl", "model.tmdl", "relationships.tmdl")
foreach ($f in $tmdlFiles) {
    $filePath = Join-Path $smDir $f
    $content = Get-Content $filePath -Raw
    $content = Replace-Placeholders -Content $content -Tokens $tokens
    $smParts += @{ path = "definition/$f"; payload = (Get-Base64String $content); payloadType = "InlineBase64" }
}

# Table TMDL files
$tablesDir = Join-Path $smDir "tables"
Get-ChildItem $tablesDir -Filter "*.tmdl" | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    $smParts += @{ path = "definition/tables/$($_.Name)"; payload = (Get-Base64String $content); payloadType = "InlineBase64" }
}

# definition.pbism
$pbismPath = Join-Path $ScriptRoot "Aether\AetherSM.SemanticModel\definition.pbism"
$smParts += @{ path = "definition.pbism"; payload = (Get-Base64File $pbismPath); payloadType = "InlineBase64" }

$smResult = Deploy-Item -WorkspaceId $WS_ID -DisplayName "AetherSM" -Type "SemanticModel" -Format "TMDL" -Parts $smParts
$SM_ID = $smResult.id

# --- Step 8: Deploy + Run Rebind Notebook ---
Write-Host "[8/14] Deploying Rebind Semantic Model Notebook"

$rebindPath = Join-Path $ScriptRoot "Aether\Rebind Semantic Model.Notebook\notebook.ipynb"
$rebindContent = Get-Content $rebindPath -Raw
$rebindContent = Replace-Placeholders -Content $rebindContent -Tokens $tokens

$rebindNb = Deploy-Item -WorkspaceId $WS_ID -DisplayName "Rebind Semantic Model" -Type "Notebook" -Format "ipynb" -Parts @(
    @{ path = "notebook.ipynb"; payload = (Get-Base64String $rebindContent); payloadType = "InlineBase64" }
)

Write-Host "  Running Rebind notebook..."
$jobResult = Invoke-FabricApi -Method "POST" -Url "$FabricApi/workspaces/$WS_ID/items/$($rebindNb.id)/jobs/instances?jobType=RunNotebook" -Body @{}
$jobId = $jobResult.id
Wait-ForJob -WorkspaceId $WS_ID -ItemId $rebindNb.id -JobInstanceId $jobId

# --- Step 9: Deploy Reports ---
Write-Host "[9/14] Deploying Reports"

$invReportResult = Deploy-Report -WorkspaceId $WS_ID `
    -ReportFolder (Join-Path $ScriptRoot "Aether Investigation.Report") `
    -DisplayName "Aether Investigation" -SemanticModelId $SM_ID
$INV_REPORT_ID = $invReportResult.id

$logsReportResult = Deploy-Report -WorkspaceId $WS_ID `
    -ReportFolder (Join-Path $ScriptRoot "Logs.Report") `
    -DisplayName "Logs" -SemanticModelId $SM_ID
$LOGS_REPORT_ID = $logsReportResult.id

# The Org App links to the Investigation report by the ID assigned by the service
# at creation time (it does not exist until the item is deployed above).
$REPORT_LOGICAL_ID = $INV_REPORT_ID

# --- Step 10: Deploy KQL Dashboard ---
Write-Host "[10/14] Deploying KQL Dashboard"

$dashPath = Join-Path $ScriptRoot "Aether\Logs.KQLDashboard\RealTimeDashboard.json"
$dashContent = Get-Content $dashPath -Raw
$dashContent = Replace-Placeholders -Content $dashContent -Tokens $tokens

$dashResult = Deploy-Item -WorkspaceId $WS_ID -DisplayName "Logs" -Type "KQLDashboard" -Format "kqlDashboard" -Parts @(
    @{ path = "RealTimeDashboard.json"; payload = (Get-Base64String $dashContent); payloadType = "InlineBase64" }
)

# --- Step 11: Deploy Data Agent ---
Write-Host "[11/14] Deploying Data Agent"

$daConfigDir = Join-Path $ScriptRoot "Aether\AetherDA.DataAgent\Files\Config"
$daParts = @()

# Collect all config files with placeholder injection
$daFiles = @(
    "data_agent.json",
    "publish_info.json",
    "draft/stage_config.json",
    "draft/kusto-AetherEH/datasource.json",
    "draft/lakehouse-tables-AetherLH/datasource.json",
    "draft/lakehouse-tables-AetherLH/fewshots.json",
    "published/stage_config.json",
    "published/kusto-AetherEH/datasource.json",
    "published/lakehouse-tables-AetherLH/datasource.json",
    "published/lakehouse-tables-AetherLH/fewshots.json"
)

foreach ($f in $daFiles) {
    $filePath = Join-Path $daConfigDir $f
    $content = Get-Content $filePath -Raw
    $content = Replace-Placeholders -Content $content -Tokens $tokens
    $daParts += @{ path = "Files/Config/$f"; payload = (Get-Base64String $content); payloadType = "InlineBase64" }
}

$daResult = Deploy-Item -WorkspaceId $WS_ID -DisplayName "AetherDA" -Type "DataAgent" -Format "dataAgent" -Parts $daParts
$DA_ID = $daResult.id
# The Org App links to the agent by its service-assigned ID (retrieved post-deploy).
$AGENT_LOGICAL_ID = $DA_ID

# --- Step 12: Deploy Org App ---
Write-Host "[12/14] Deploying Org App"

$tokens["REPORT_LOGICAL_ID"] = $REPORT_LOGICAL_ID
$tokens["AGENT_LOGICAL_ID"] = $AGENT_LOGICAL_ID

$orgAppPath = Join-Path $ScriptRoot "Aether\Aether App.OrgApp\definition.json"
$orgAppContent = Get-Content $orgAppPath -Raw
$orgAppContent = Replace-Placeholders -Content $orgAppContent -Tokens $tokens

$orgAppResult = Deploy-Item -WorkspaceId $WS_ID -DisplayName "Aether App" -Type "OrgApp" -Format "orgApp" -Parts @(
    @{ path = "definition.json"; payload = (Get-Base64String $orgAppContent); payloadType = "InlineBase64" }
)

# --- Step 13: Deploy Event Simulator Notebook ---
Write-Host "[13/14] Deploying Event Simulator Notebook"

$simPath = Join-Path $ScriptRoot "Aether\Event Simulator.Notebook\notebook.ipynb"
$simContent = Get-Content $simPath -Raw
$simContent = $simContent -replace '"id": ""', "`"id`": `"$LH_ID`""

$simNb = Deploy-Item -WorkspaceId $WS_ID -DisplayName "Event Simulator" -Type "Notebook" -Format "ipynb" -Parts @(
    @{ path = "notebook.ipynb"; payload = (Get-Base64String $simContent); payloadType = "InlineBase64" }
)

Write-Host "  NOTE: Event Simulator is NOT auto-run. Start it manually when ready for the demo."

# --- Step 14: Create Mirrored Database for audience votes ---
Write-Host "[14/14] Creating Mirrored Database for audience votes"

$mirrorBody = @{
    displayName = "Votes Mirror"
    type        = "MirroredDatabase"
}
$mirrorResult = Invoke-FabricApi -Method "POST" -Url "$FabricApi/workspaces/$WS_ID/items" -Body $mirrorBody
$MIRROR_ID = $mirrorResult.id
Write-Host "  Created: Votes Mirror (MirroredDatabase) -> $MIRROR_ID"
Write-Host "  NOTE: In the Fabric portal, configure 'Votes Mirror' to point at the OneDrive Excel file synced from Microsoft Forms."
Write-Host "  NOTE: After mirroring is configured, create a shortcut in the AetherEH KQL Database so the dashboard's Votes queries resolve to the mirrored table."

# ============================================================
# Summary
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Deployment Complete!"
Write-Host "============================================================"
Write-Host ""
Write-Host "Workspace:        $WorkspaceName"
Write-Host "Workspace ID:     $WS_ID"
Write-Host ""
Write-Host "Items Deployed:"
Write-Host "  Eventhouse:       $EH_ID"
Write-Host "  KQL Database:     $KQL_DB_ID"
Write-Host "  Lakehouse:        $LH_ID"
Write-Host "  Semantic Model:   $SM_ID"
Write-Host "  Investigation:    $INV_REPORT_ID"
Write-Host "  Logs Report:      $LOGS_REPORT_ID"
Write-Host "  Data Agent:       $DA_ID"
Write-Host "  KQL Dashboard:    $($dashResult.id)"
Write-Host "  Org App:          $($orgAppResult.id)"
Write-Host "  Event Simulator:  $($simNb.id)"
Write-Host "  Votes Mirror:     $MIRROR_ID"
Write-Host ""
Write-Host "Portal: https://app.fabric.microsoft.com/groups/$WS_ID"
Write-Host ""
Write-Host "Next Steps:"
Write-Host "  1. Set AETHER_EVENTHUB_CONNECTION_STRING in the Event Simulator notebook"
Write-Host "  2. Run Event Simulator to begin the live demo"
Write-Host "  3. Create a public MS Form, enable 'sync responses to Excel' in OneDrive"
Write-Host "  4. In the Fabric portal, open 'Votes Mirror' and configure the landing zone to point at the Excel file"
Write-Host "  5. Submit a test response and verify it appears in the mirrored database"
