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
        [object]$Body = $null,
        [string]$Resource = $FabricResource
    )

    $args = @("rest", "--method", $Method, "--resource", $Resource, "--url", $Url)
    $bodyFile = $null

    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        # Pass the JSON via a temp file (--body "@file"). Passing raw JSON inline to
        # az on Windows/PowerShell strips the inner double quotes, corrupting the body.
        $bodyFile = New-TemporaryFile
        [System.IO.File]::WriteAllText($bodyFile.FullName, $json, [System.Text.UTF8Encoding]::new($false))
        $args += @("--body", "@$($bodyFile.FullName)")
        $args += @("--headers", "Content-Type=application/json")
    }

    try {
        $maxAttempts = 5
        for ($attempt = 1; ; $attempt++) {
            $result = az @args 2>&1
            if ($LASTEXITCODE -eq 0) { break }

            # Retry transient network/proxy/service failures; fail fast on real API errors.
            $errText = "$result"
            $transient = $errText -match 'SSLError|Max retries|Connection (reset|aborted)|timed out|TooManyRequests|ServiceUnavailable|Gateway|InternalServiceError|[Ii]nternal service error|Request aborted|\b(429|500|502|503|504)\b|temporarily'
            if ($attempt -ge $maxAttempts -or -not $transient) {
                throw "API call failed: $Method $Url`n$result"
            }
            Write-Host "  Transient error (attempt $attempt); retrying in $([Math]::Min(30, 5 * $attempt))s..."
            Start-Sleep -Seconds ([Math]::Min(30, 5 * $attempt))
        }
    }
    finally {
        if ($bodyFile) { Remove-Item $bodyFile.FullName -Force -ErrorAction SilentlyContinue }
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

function Set-NotebookLakehouse {
    param(
        [string]$NotebookPath,
        [string]$LakehouseId,
        [string]$LakehouseName,
        [string]$WorkspaceId
    )

    # Fabric notebooks resolve %%sql / saveAsTable against a "default lakehouse" declared
    # in notebook metadata (metadata.dependencies.lakehouse). Without it the Spark
    # statements have no catalog to write to and the run fails.
    $nb = Get-Content $NotebookPath -Raw | ConvertFrom-Json

    $lakehouse = [pscustomobject]@{
        default_lakehouse              = $LakehouseId
        default_lakehouse_name         = $LakehouseName
        default_lakehouse_workspace_id = $WorkspaceId
        known_lakehouses               = @([pscustomobject]@{ id = $LakehouseId })
    }
    $deps = [pscustomobject]@{ lakehouse = $lakehouse }

    if ($nb.metadata.PSObject.Properties.Name -contains 'dependencies') {
        $nb.metadata.dependencies = $deps
    }
    else {
        $nb.metadata | Add-Member -NotePropertyName dependencies -NotePropertyValue $deps
    }

    return ($nb | ConvertTo-Json -Depth 40)
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

function Wait-ForItemByName {
    param(
        [string]$WorkspaceId,
        [string]$DisplayName,
        [string]$Type,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $items = Invoke-FabricApi -Method "GET" -Url "$FabricApi/workspaces/$WorkspaceId/items?type=$Type"
        $match = $items.value | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
        if ($match) { return $match }
        Start-Sleep -Seconds 5
    }
    throw "Item '$DisplayName' ($Type) did not appear within $TimeoutSeconds seconds"
}

function Start-ItemJob {
    param(
        [string]$WorkspaceId,
        [string]$ItemId,
        [string]$JobType,
        [int]$TimeoutSeconds = 90
    )

    $before = (Get-Date).ToUniversalTime()
    Invoke-FabricApi -Method "POST" -Url "$FabricApi/workspaces/$WorkspaceId/items/$ItemId/jobs/instances?jobType=$JobType" -Body @{} | Out-Null

    # The run job returns 202 with only a Location header (no body), so the instance id
    # isn't available inline. Poll the instances list for the newly-created run.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $insts = Invoke-FabricApi -Method "GET" -Url "$FabricApi/workspaces/$WorkspaceId/items/$ItemId/jobs/instances"
        $latest = $insts.value | Sort-Object { [datetime]$_.startTimeUtc } -Descending | Select-Object -First 1
        if ($latest) { return $latest.id }
        Start-Sleep -Seconds 3
    }
    throw "No job instance appeared for item $ItemId"
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
    }

    # Some item types (e.g. Eventhouse, Lakehouse) are created without a definition
    # envelope; the service provisions their child items automatically. Others (e.g.
    # KQLDashboard) take a definition with parts but no format field.
    if ($Parts) {
        $body.definition = @{ parts = $Parts }
        if ($Format) { $body.definition.format = $Format }
    }

    $result = Invoke-FabricApi -Method "POST" -Url "$FabricApi/workspaces/$WorkspaceId/items" -Body $body

    # Definition-based creates run as a long-running operation and return 202 with no
    # body, so no id is available inline. Resolve the item by name once provisioned.
    if (-not $result -or -not $result.id) {
        $result = Wait-ForItemByName -WorkspaceId $WorkspaceId -DisplayName $DisplayName -Type $Type
    }

    Write-Host "  Created: $DisplayName ($Type) -> $($result.id)"
    return $result
}

function Deploy-Report {
    param(
        [string]$WorkspaceId,
        [string]$ReportFolder,
        [string]$DisplayName,
        [string]$SemanticModelId,
        [string]$SemanticModelName,
        [string]$WorkspaceName
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
            # connection. The PBIR 2.0.0 schema's byConnection accepts only a
            # connectionString; the service requires the semantic model GUID embedded
            # as the semanticModelId parameter.
            $connStr = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/$WorkspaceName;Initial Catalog=$SemanticModelName;semanticModelId=$SemanticModelId"
            $pbir = Get-Content $file.FullName -Raw | ConvertFrom-Json
            $pbir.datasetReference = @{
                byConnection = @{
                    connectionString = $connStr
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
Write-Host "[1/15] Resolving workspace: $WorkspaceName"

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
Write-Host "[2/15] Creating Eventhouse + KQL Database"

$ehResult = Deploy-Item -WorkspaceId $WS_ID -DisplayName "AetherEH" -Type "Eventhouse"
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
Write-Host "[3/15] Creating Lakehouse"

$lhResult = Deploy-Item -WorkspaceId $WS_ID -DisplayName "AetherLH" -Type "Lakehouse"
$LH_ID = $lhResult.id
Write-Host "  Lakehouse ID: $LH_ID"

# --- Step 4: Deploy KQL Schema ---
Write-Host "[4/15] Deploying KQL Schema"

$schemaPath = Join-Path $ScriptRoot "Aether\AetherEH.Eventhouse\.children\AetherEH.KQLDatabase\DatabaseSchema.kql"
$schemaContent = Get-Content $schemaPath -Raw

# Execute each .create-merge command against the KQL database
$commands = $schemaContent -split '(?=\.create-merge)' | Where-Object { $_.Trim() -ne "" -and $_ -match '\.create-merge' }
foreach ($cmd in $commands) {
    $cmdBody = @{ csl = $cmd.Trim(); db = "AetherEH" }
    Invoke-FabricApi -Method "POST" -Url "$CLUSTER_URI/v1/rest/mgmt" -Body $cmdBody -Resource $CLUSTER_URI
    Write-Host "  Executed: $($cmd.Substring(0, [Math]::Min(60, $cmd.Length)))..."
}

# Enable OneLake availability on the tables that are exposed to the Lakehouse via
# shortcuts. Without this policy, the KQL table has no OneLake (Tables/<name>) path
# for a shortcut to target.
$availTables = @("SecurityLogs", "Communications", "VictimCalendar", "SupplierRecords")
foreach ($t in $availTables) {
    $csl = ".alter-merge table $t policy mirroring dataformat=parquet with (IsEnabled=true, TargetLatencyInMinutes=5)"
    Invoke-FabricApi -Method "POST" -Url "$CLUSTER_URI/v1/rest/mgmt" -Body @{ csl = $csl; db = "AetherEH" } -Resource $CLUSTER_URI
    Write-Host "  OneLake availability enabled: $t"
}

# --- Step 5: Create Shortcuts ---
Write-Host "[5/15] Creating Shortcuts (Eventhouse -> Lakehouse)"

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

# OneLake availability materializes the table paths asynchronously; give it time
# before creating shortcuts, and retry transient "path not found" style failures.
Write-Host "  Waiting for OneLake table paths to materialize..."
Start-Sleep -Seconds 30

foreach ($sc in $shortcuts.shortcuts) {
    $scBody = @{
        path   = $sc.path
        name   = $sc.name
        target = $sc.target
    }

    $attempt = 0
    while ($true) {
        try {
            Invoke-FabricApi -Method "POST" -Url "$FabricApi/workspaces/$WS_ID/items/$LH_ID/shortcuts" -Body $scBody
            Write-Host "  Shortcut: $($sc.name)"
            break
        }
        catch {
            $attempt++
            if ($attempt -ge 6) { throw }
            Write-Host "  Shortcut $($sc.name) not ready (attempt $attempt); retrying in 20s..."
            Start-Sleep -Seconds 20
        }
    }
}

# --- Step 6: Deploy + Run Populate Notebook ---
Write-Host "[6/15] Deploying Populate Lakehouse Notebook"

$popNbPath = Join-Path $ScriptRoot "Aether\Populate Lakehouse.Notebook\notebook.ipynb"
# Attach AetherLH as the notebook's default lakehouse so %%sql / saveAsTable resolve.
$popNbContent = Set-NotebookLakehouse -NotebookPath $popNbPath -LakehouseId $LH_ID -LakehouseName "AetherLH" -WorkspaceId $WS_ID

$popNb = Deploy-Item -WorkspaceId $WS_ID -DisplayName "Populate Lakehouse" -Type "Notebook" -Format "ipynb" -Parts @(
    @{ path = "notebook.ipynb"; payload = (Get-Base64String $popNbContent); payloadType = "InlineBase64" }
)

Write-Host "  Running Populate Lakehouse notebook..."
$jobId = Start-ItemJob -WorkspaceId $WS_ID -ItemId $popNb.id -JobType "RunNotebook"
Wait-ForJob -WorkspaceId $WS_ID -ItemId $popNb.id -JobInstanceId $jobId

# --- Step 7: Deploy Semantic Model ---
Write-Host "[7/15] Deploying Semantic Model"

# Resolve the Lakehouse SQL analytics endpoint and inject it into the Direct Lake
# model connection so it binds to this workspace's lakehouse at deploy time.
Write-Host "  Resolving Lakehouse SQL endpoint..."
$sqlServer = $null; $sqlDbId = $null
$deadline = (Get-Date).AddSeconds(300)
while ((Get-Date) -lt $deadline) {
    $lh = Invoke-FabricApi -Method "GET" -Url "$FabricApi/workspaces/$WS_ID/lakehouses/$LH_ID"
    $sqlProps = $lh.properties.sqlEndpointProperties
    if ($sqlProps -and $sqlProps.provisioningStatus -eq "Success" -and $sqlProps.connectionString) {
        $sqlServer = $sqlProps.connectionString
        $sqlDbId = $sqlProps.id
        break
    }
    Start-Sleep -Seconds 10
}
if (-not $sqlServer) { throw "Lakehouse SQL endpoint did not provision in time" }
Write-Host "  SQL endpoint: $sqlServer (db $sqlDbId)"
$tokens["LAKEHOUSE_SQL_ENDPOINT"] = $sqlServer
$tokens["LAKEHOUSE_SQL_DB_ID"] = $sqlDbId

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
Write-Host "[8/15] Deploying Rebind Semantic Model Notebook"

$rebindPath = Join-Path $ScriptRoot "Aether\Rebind Semantic Model.Notebook\notebook.ipynb"
$rebindContent = Get-Content $rebindPath -Raw
$rebindContent = Replace-Placeholders -Content $rebindContent -Tokens $tokens

$rebindNb = Deploy-Item -WorkspaceId $WS_ID -DisplayName "Rebind Semantic Model" -Type "Notebook" -Format "ipynb" -Parts @(
    @{ path = "notebook.ipynb"; payload = (Get-Base64String $rebindContent); payloadType = "InlineBase64" }
)

# The model connection is already injected at deploy time (step 7), so this rebind
# is a redundant safety net; don't let a transient sempy/pip failure abort the deploy.
Write-Host "  Running Rebind notebook..."
try {
    $jobId = Start-ItemJob -WorkspaceId $WS_ID -ItemId $rebindNb.id -JobType "RunNotebook"
    Wait-ForJob -WorkspaceId $WS_ID -ItemId $rebindNb.id -JobInstanceId $jobId
}
catch {
    Write-Host "  WARNING: Rebind notebook run failed ($_). The model connection was already"
    Write-Host "           set at deploy time, so continuing. Re-run the notebook manually if needed."
}

# --- Step 9: Deploy Reports ---
Write-Host "[9/15] Deploying Reports"

$invReportResult = Deploy-Report -WorkspaceId $WS_ID `
    -ReportFolder (Join-Path $ScriptRoot "Aether Investigation.Report") `
    -DisplayName "Aether Investigation" -SemanticModelId $SM_ID `
    -SemanticModelName "AetherSM" -WorkspaceName $WorkspaceName
$INV_REPORT_ID = $invReportResult.id

$logsReportResult = Deploy-Report -WorkspaceId $WS_ID `
    -ReportFolder (Join-Path $ScriptRoot "Logs.Report") `
    -DisplayName "Logs" -SemanticModelId $SM_ID `
    -SemanticModelName "AetherSM" -WorkspaceName $WorkspaceName
$LOGS_REPORT_ID = $logsReportResult.id

# The Org App links to the Investigation report by the ID assigned by the service
# at creation time (it does not exist until the item is deployed above).
$REPORT_LOGICAL_ID = $INV_REPORT_ID

# --- Step 10: Deploy KQL Dashboard ---
Write-Host "[10/15] Deploying KQL Dashboard"

$dashPath = Join-Path $ScriptRoot "Aether\Logs.KQLDashboard\RealTimeDashboard.json"
$dashContent = Get-Content $dashPath -Raw
$dashContent = Replace-Placeholders -Content $dashContent -Tokens $tokens

$dashResult = Deploy-Item -WorkspaceId $WS_ID -DisplayName "Logs" -Type "KQLDashboard" -Parts @(
    @{ path = "RealTimeDashboard.json"; payload = (Get-Base64String $dashContent); payloadType = "InlineBase64" }
)

$audDashPath = Join-Path $ScriptRoot "Aether\AudienceVotes.KQLDashboard\RealTimeDashboard.json"
$audDashContent = Get-Content $audDashPath -Raw
$audDashContent = Replace-Placeholders -Content $audDashContent -Tokens $tokens

$audDashResult = Deploy-Item -WorkspaceId $WS_ID -DisplayName "Audience Votes" -Type "KQLDashboard" -Parts @(
    @{ path = "RealTimeDashboard.json"; payload = (Get-Base64String $audDashContent); payloadType = "InlineBase64" }
)

# --- Step 11: Deploy Data Agent ---
Write-Host "[11/15] Deploying Data Agent"

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

$daResult = Deploy-Item -WorkspaceId $WS_ID -DisplayName "AetherDA" -Type "DataAgent" -Parts $daParts
$DA_ID = $daResult.id

# --- Step 12: Deploy Org App ---
Write-Host "[12/15] Deploying Org App"

# Item elements bind by itemId + folderObjectId (the workspace id is the root folder).
# NOTE: Org Apps do not currently accept Data Agents as item elements (the service
# rejects itemType "DataAgent"/"AISkill"), so the app surfaces the report only; the
# Data Agent is still deployed and can be used directly from the workspace.
$tokens["REPORT_LOGICAL_ID"] = $REPORT_LOGICAL_ID

$orgAppPath = Join-Path $ScriptRoot "Aether\Aether App.OrgApp\definition.json"
$orgAppContent = Get-Content $orgAppPath -Raw
$orgAppContent = Replace-Placeholders -Content $orgAppContent -Tokens $tokens

$orgAppResult = Deploy-Item -WorkspaceId $WS_ID -DisplayName "Aether App" -Type "OrgApp" -Parts @(
    @{ path = "definition.json"; payload = (Get-Base64String $orgAppContent); payloadType = "InlineBase64" }
)

# --- Step 13: Deploy Eventstream (auto-provisions the Event Hub connection) ---
Write-Host "[13/15] Deploying Eventstream (AetherES)"

$esJsonPath = Join-Path $ScriptRoot "Aether\AetherES.Eventstream\eventstream.json"
$esPlatformPath = Join-Path $ScriptRoot "Aether\AetherES.Eventstream\.platform"
$esContent = Get-Content $esJsonPath -Raw
$esContent = Replace-Placeholders -Content $esContent -Tokens $tokens
$esPlatformContent = Get-Content $esPlatformPath -Raw

$esItem = Deploy-Item -WorkspaceId $WS_ID -DisplayName "AetherES" -Type "Eventstream" -Parts @(
    @{ path = "eventstream.json"; payload = (Get-Base64String $esContent); payloadType = "InlineBase64" }
    @{ path = ".platform"; payload = (Get-Base64String $esPlatformContent); payloadType = "InlineBase64" }
)
$ES_ID = $esItem.id

# The CustomEndpoint source exposes an Event Hub-compatible connection string, which is
# exactly what the Event Simulator publishes to. Poll the topology for the source id,
# then fetch its primary connection string so we can inject it into the notebook below.
$EVENTHUB_CONN = $null
$esDeadline = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $esDeadline) {
    try {
        $topology = Invoke-FabricApi -Method "GET" -Url "$FabricApi/workspaces/$WS_ID/eventstreams/$ES_ID/topology"
        $source = $topology.sources | Where-Object { $_.type -eq "CustomEndpoint" } | Select-Object -First 1
        if ($source -and $source.id) {
            $conn = Invoke-FabricApi -Method "GET" -Url "$FabricApi/workspaces/$WS_ID/eventstreams/$ES_ID/sources/$($source.id)/connection"
            if ($conn.accessKeys.primaryConnectionString) {
                $EVENTHUB_CONN = $conn.accessKeys.primaryConnectionString
                break
            }
        }
    }
    catch {
        Write-Host "  Eventstream source not ready yet; retrying in 15s..."
    }
    Start-Sleep -Seconds 15
}

if (-not $EVENTHUB_CONN) {
    Write-Host "  WARNING: Could not retrieve the Eventstream connection string automatically."
    Write-Host "           Set AETHER_EVENTHUB_CONNECTION_STRING on the Event Simulator before running."
}
else {
    Write-Host "  Retrieved Event Hub connection string from the AetherES CustomEndpoint source."
}

# --- Step 14: Deploy Event Simulator Notebook ---
Write-Host "[14/15] Deploying Event Simulator Notebook"

$simPath = Join-Path $ScriptRoot "Aether\Event Simulator.Notebook\notebook.ipynb"
$simContent = Get-Content $simPath -Raw
$simContent = $simContent -replace '"id": ""', "`"id`": `"$LH_ID`""
if ($EVENTHUB_CONN) {
    # Literal replace (not -replace) so any regex-special chars in the key are safe.
    $simContent = $simContent.Replace("{{EVENTHUB_CONNECTION_STRING}}", $EVENTHUB_CONN)
}

$simNb = Deploy-Item -WorkspaceId $WS_ID -DisplayName "Event Simulator" -Type "Notebook" -Format "ipynb" -Parts @(
    @{ path = "notebook.ipynb"; payload = (Get-Base64String $simContent); payloadType = "InlineBase64" }
)

Write-Host "  NOTE: Event Simulator is NOT auto-run. Start it manually when ready for the demo."

# --- Step 15: Create Mirrored Database for audience votes ---
Write-Host "[15/15] Creating Mirrored Database for audience votes"

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
Write-Host "  Audience Votes:   $($audDashResult.id)"
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
