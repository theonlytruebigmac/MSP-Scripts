#Requires -Version 7.0
<#
.SYNOPSIS
    Interactive demo: pick an organization, find a repository script, find a device
    in that org, run the script on it, and gather the result — via the N-able
    GraphQL API.

.DESCRIPTION
    Guided, interactive workflow designed for live demos:
      1. Pick an organization
      2. Search for and choose a script in that org
      3. Search for and choose a device in that org
      4. Fill in the script's input variables, confirm, and run
      5. Poll until complete and display the result

    Any search term can be pre-supplied as a parameter; anything omitted is prompted
    for interactively. At each search step you can type 'r' to search again. All
    GraphQL operations are validated against the live N-able schema
    (organizationSearch / organization, scriptSearch, assetSearch, assetsScriptRun,
    task).

.PARAMETER ApiKey
    Your N-able API-Access token, sent as a Bearer credential (Authorization:
    Bearer <token>). Generate it in the N-able dashboard (API client / "Generate
    JSON Web Token"). The token is used exactly as issued — it may be a JWT or an
    N-central-style key (e.g. a 64-hex string with a "-N" suffix). A plain object
    id / UUID is NOT a token and fails with HTTP 403 "RBAC: access denied".

.PARAMETER ApiBaseUrl
    Base URL for the N-able GraphQL API endpoint. Example: https://api.n-able.com/graphql

.PARAMETER OrganizationName
    Optional pre-fill for the organization search. Omit to be prompted.

.PARAMETER OrganizationId
    Optional exact organization ID. Skips the org search.

.PARAMETER ScriptName
    Optional pre-fill for the script search.

.PARAMETER DeviceName
    Optional pre-fill for the device search.

.PARAMETER TaskName
    Friendly label for this run (max 128 chars). Defaults to a timestamped name.

.PARAMETER ScriptInputs
    Optional hashtable of script input values keyed by the script's *variable*
    name. Any declared variable not supplied here is prompted for interactively.
    Example: @{ "targetPath" = "C:\Temp"; "maxRetries" = 3 }

.PARAMETER ScriptTimeoutSeconds
    Per-run execution timeout (0-3600). 0 (default) uses the script's own
    configured timeout; the API treats 0 as the max (3600s).

.PARAMETER PollIntervalSeconds
    How often (seconds) to check task status. Default: 5.

.PARAMETER MaxWaitSeconds
    Stop polling after this many seconds even if unfinished. Default: 600.

.PARAMETER AssumeYes
    Skip the final "run this now?" confirmation (useful for scripted runs).

.EXAMPLE
    .\Invoke-NAbleScriptRun.ps1 -ApiKey "KEYHERE" -ApiBaseUrl "https://api.n-able.com/graphql"
    # Fully interactive — prompts for org, script, device, and inputs.

.EXAMPLE
    .\Invoke-NAbleScriptRun.ps1 -ApiKey "KEYHERE" -ApiBaseUrl "https://api.n-able.com/graphql" `
        -OrganizationName "FocusMSP" -ScriptName "App Usage Tracker" -DeviceName "SLS-2188"
    # Pre-fills every search term; still lets you confirm each selection.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ApiKey,

  [Parameter(Mandatory)]
  [string]$ApiBaseUrl,

  [string]$OrganizationName,

  [string]$OrganizationId,

  [string]$ScriptName,

  [string]$DeviceName,

  [string]$TaskName = "Claude Demo Run - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",

  [hashtable]$ScriptInputs = @{},

  [ValidateRange(0, 3600)]
  [int]$ScriptTimeoutSeconds = 0,

  [ValidateRange(1, 3600)]
  [int]$PollIntervalSeconds = 5,

  [ValidateRange(1, 86400)]
  [int]$MaxWaitSeconds = 600,

  [switch]$AssumeYes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helper: Execute a GraphQL operation
# ---------------------------------------------------------------------------
function Invoke-GraphQL {
  param(
    [Parameter(Mandatory)][string]$Query,
    [hashtable]$Variables = @{},
    [switch]$ToleratePartialData
  )

  $body = @{
    query = $Query
    variables = $Variables
  } | ConvertTo-Json -Depth 20 -Compress

  $headers = @{
    'Content-Type'  = 'application/json'
    'Authorization' = "Bearer $ApiKey"
  }

  try {
    $statusCode = 0
    $response = Invoke-RestMethod -Uri $ApiBaseUrl -Method POST -Headers $headers `
      -Body $body -SkipHttpErrorCheck -StatusCodeVariable statusCode
  }
  catch {
    throw "N-able API request failed (transport error): $($_.Exception.Message)"
  }

  if ($null -ne $response -and $response.PSObject.Properties['errors'] -and $response.errors) {
    $errMsg = ($response.errors | ForEach-Object { $_.message }) -join '; '
    $hasData = $response.PSObject.Properties['data'] -and $null -ne $response.data
    if ($ToleratePartialData -and $hasData) {
      Write-Verbose "Partial GraphQL response [HTTP $statusCode]: $errMsg"
    }
    else {
      throw "GraphQL error(s) [HTTP $statusCode]: $errMsg"
    }
  }

  if ($statusCode -ge 400) {
    throw "N-able API returned HTTP $statusCode with no GraphQL error detail."
  }

  if ($null -eq $response -or -not $response.PSObject.Properties['data']) {
    throw "N-able API response contained no 'data' field."
  }

  return $response.data
}

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "    [OK] $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }

function Get-OrgName {
  param($OrgObject)
  if ($OrgObject -and $OrgObject.PSObject.Properties['name'] -and $OrgObject.name) {
    return $OrgObject.name
  }
  return '(none)'
}

function Select-Interactively {
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][scriptblock]$SearchFn,
    [Parameter(Mandatory)][scriptblock]$FormatFn,
    [string]$InitialTerm
  )

  $term = $InitialTerm
  while ($true) {
    if ([string]::IsNullOrWhiteSpace($term)) {
      $term = Read-Host "    Search for $Label by name"
      if ([string]::IsNullOrWhiteSpace($term)) { continue }
    }

    Write-Host "    Searching for $Label matching '$term'..." -ForegroundColor DarkGray
    $results = @(& $SearchFn $term)

    if ($results.Count -eq 0) {
      Write-Host "    No $Label found matching '$term'. Try a different term." -ForegroundColor Yellow
      $term = $null
      continue
    }

    while ($true) {
      Write-Host ""
      for ($i = 0; $i -lt $results.Count; $i++) {
        Write-Host ("    [{0}] {1}" -f $i, (& $FormatFn $results[$i]))
      }
      Write-Host "    [r] Search again"
      $sel = Read-Host "    Select $Label (0-$($results.Count - 1), or r)"

      if ($sel -in @('r', 'R')) { $term = $null; break } # re-search
      if ($sel -match '^\d+$' -and [int]$sel -lt $results.Count) {
        return $results[[int]$sel]
      }
      Write-Host "    Invalid selection — enter 0-$($results.Count - 1) or 'r'." -ForegroundColor Yellow
    }
  }
}

function Read-YesNo {
  param([string]$Prompt, [switch]$DefaultYes)
  $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
  $answer = Read-Host "$Prompt $suffix"
  if ([string]::IsNullOrWhiteSpace($answer)) { return [bool]$DefaultYes }
  return $answer -match '^(y|yes)$'
}

# ===========================================================================
Write-Host ""
Write-Host "  N-able GraphQL — Script Execution Demo" -ForegroundColor White
Write-Host "  ---------------------------------------" -ForegroundColor White

# ===========================================================================
# STEP 1 — Choose the organization
# ===========================================================================
Write-Step "Step 1: Select organization"

if ($OrganizationId) {
  $orgData = Invoke-GraphQL -Query @'
query GetOrg($id: ID!) {
  organization(id: $id) { id name __typename }
}
'@ -Variables @{ id = $OrganizationId }
    $org = $orgData.organization
    if (-not $org) {
        Write-Error "No organization found with ID '$OrganizationId'. Exiting."
        exit 1
    }
}
else {
    $orgSearchQuery = @'
query FindOrgs($name: String!) {
  organizationSearch(where: { name: { contains: $name } }, first: 25) {
    nodes { id name __typename }
  }
}
'@
  $org = Select-Interactively -Label 'organization' -InitialTerm $OrganizationName `
    -SearchFn {
    param($term)
    (Invoke-GraphQL -Query $orgSearchQuery -Variables @{ name = $term }).organizationSearch.nodes
  } `
    -FormatFn { param($n) "$($n.name)  ($($n.__typename))" }
}

Write-Success "Using organization: $($org.name)"
Write-Info "  ID:   $($org.id)"
Write-Info "  Type: $($org.__typename)"

# ===========================================================================
# STEP 2 — Find and choose the script (within the selected org)
# ===========================================================================
Write-Step "Step 2: Find a script to execute"

$scriptSearchQuery = @'
query FindScript($orgIds: [ID!]!, $name: String!) {
  scriptSearch(
    inOrganizations: $orgIds
    where: { name: { contains: $name } }
    first: 15
  ) {
    nodes {
      id
      name
      language
      description
      timeoutSeconds
      inputs { name variable type }
    }
  }
}
'@

$script = Select-Interactively -Label 'script' -InitialTerm $ScriptName `
  -SearchFn {
  param($term)
  (Invoke-GraphQL -Query $scriptSearchQuery -Variables @{ orgIds = @($org.id); name = $term }).scriptSearch.nodes
} `
  -FormatFn { param($n) "$($n.name)  ($($n.language))" }

$declaredInputs = @($script.inputs)

Write-Success "Selected script: $($script.name)"
Write-Info "  ID:       $($script.id)"
Write-Info "  Language: $($script.language)"
if ($script.description) { Write-Info "  Description: $($script.description)" }
if ($declaredInputs.Count -gt 0) {
  Write-Info "  Input variables:"
  $declaredInputs | ForEach-Object { Write-Info "    - $($_.name) [$($_.variable)] ($($_.type))" }
}

# ===========================================================================
# STEP 3 — Find and choose the device (within the selected org)
# ===========================================================================
Write-Step "Step 3: Find a device to run it against"

$assetSearchQuery = @'
query FindAsset($orgIds: [ID!]!, $name: String!) {
  assetSearch(
    inOrganizations: $orgIds
    where: { name: { contains: $name } }
    first: 10
  ) {
    nodes {
      id
      name
      customer { name }
      site { name }
      agentConnection { status }
    }
  }
}
'@

$asset = Select-Interactively -Label 'device' -InitialTerm $DeviceName `
  -SearchFn {
  param($term)
  (Invoke-GraphQL -Query $assetSearchQuery -Variables @{ orgIds = @($org.id); name = $term }).assetSearch.nodes
} `
  -FormatFn {
  param($n)
  $status = if ($n.agentConnection) { $n.agentConnection.status } else { 'UNKNOWN' }
  "$($n.name)  [$status]  (Customer: $(Get-OrgName $n.customer), Site: $(Get-OrgName $n.site))"
}

$agentStatus = if ($asset.agentConnection) { $asset.agentConnection.status } else { 'UNKNOWN' }

Write-Success "Selected device: $($asset.name)"
Write-Info "  ID:       $($asset.id)"
Write-Info "  Agent:    $agentStatus"
Write-Info "  Customer: $(Get-OrgName $asset.customer)"
Write-Info "  Site:     $(Get-OrgName $asset.site)"
if ($agentStatus -ne 'CONNECTED') {
  Write-Host "    [warn] Agent is $agentStatus — the run may not execute until the device reconnects." -ForegroundColor Yellow
}

# ===========================================================================
# STEP 4 — Collect inputs, confirm, and kick off the run
# ===========================================================================
Write-Step "Step 4: Configure and run"

if ($declaredInputs.Count -gt 0) {
  Write-Info "Enter values for the script's input variables (leave blank to skip):"
  foreach ($decl in $declaredInputs) {
    if ($ScriptInputs.ContainsKey($decl.variable)) {
      Write-Info "  $($decl.name) [$($decl.variable)] = (supplied via -ScriptInputs)"
      continue
    }

    if ($decl.type -eq 'PASSWORD') {
      $secure = Read-Host "      $($decl.name) [$($decl.variable)] (PASSWORD)" -AsSecureString
      if ($secure.Length -gt 0) {
        $ScriptInputs[$decl.variable] = ConvertFrom-SecureString $secure -AsPlainText
      }
    }
    else {
      $val = Read-Host "      $($decl.name) [$($decl.variable)] ($($decl.type))"
      if (-not [string]::IsNullOrWhiteSpace($val)) {
        $ScriptInputs[$decl.variable] = $val
      }
    }
  }
}

$declaredVarNames = @($declaredInputs | ForEach-Object { $_.variable })
foreach ($key in $ScriptInputs.Keys) {
  if ($declaredVarNames -notcontains $key) {
    Write-Host "    [warn] Input '$key' is not a declared variable on this script — ignored." -ForegroundColor Yellow
  }
}

$inputValues = @()
foreach ($decl in $declaredInputs) {
  if (-not $ScriptInputs.ContainsKey($decl.variable)) { continue }
  $raw = $ScriptInputs[$decl.variable]

  $valueObj = switch ($decl.type) {
    'BOOLEAN' { @{ booleanValue = [bool]$raw } }
    'INT' { @{ intValue = [int]$raw } }
    'FLOAT' { @{ floatValue = [double]$raw } }
    'DATE_TIME' { @{ dateTimeValue = [string]$raw } } # ISO-8601 / RFC 3339
    default { @{ stringValue = [string]$raw } } # STRING, PASSWORD
  }

  $inputValues += @{
    name = $decl.name
    variable = $decl.variable
    type = $decl.type
    value = $valueObj
  }
}

$effectiveTimeout = if ($ScriptTimeoutSeconds -gt 0) { $ScriptTimeoutSeconds } else { [int]$script.timeoutSeconds }
$effectiveName = if ($TaskName.Length -gt 128) { $TaskName.Substring(0, 128) } else { $TaskName }

Write-Host ""
Write-Host "    About to run:" -ForegroundColor White
Write-Host "      Script:   $($script.name)  ($($script.language))"
Write-Host "      Device:   $($asset.name)  [$agentStatus]"
Write-Host "      Org:      $($org.name)"
Write-Host "      Task:     $effectiveName"
Write-Host "      Timeout:  $(if ($effectiveTimeout -eq 0) { 'max (3600s)' } else { "${effectiveTimeout}s" })"
if ($inputValues.Count -gt 0) {
  Write-Host "      Inputs:"
  $inputValues | ForEach-Object {
    $shown = if ($_.type -eq 'PASSWORD') { '********' } else { $_.value.Values | Select-Object -First 1 }
    Write-Host "        - $($_.variable) = $shown"
  }
}
Write-Host ""

if (-not $AssumeYes) {
  if (-not (Read-YesNo -Prompt "    Run this script now?")) {
    Write-Host "    Cancelled — nothing was executed." -ForegroundColor Yellow
    exit 0
  }
}

$runMutation = @'
mutation RunScript($input: AssetsScriptRunMutationInput!) {
  assetsScriptRun(input: $input) {
    # Only select `id` here. On a just-created task the non-nullable String
    # fields (name) resolve to null and error the whole response; name/status
    # are read from the polling step instead.
    items { id }
    errors {
      __typename
      ... on ScriptRunNotPermittedError   { message asset { id name } }
      ... on ScriptRunValidationError     { message asset { id name } }
      ... on ScriptRunAssetNotFoundError  { message assetId }
      ... on ScriptRunScriptNotFoundError { message assetId }
    }
  }
}
'@

$configuration = @{
  scriptId = $script.id
  name = $effectiveName
  timeoutSeconds = $effectiveTimeout
}
if ($inputValues.Count -gt 0) { $configuration.inputs = @($inputValues) }

$runVariables = @{
  input = @{
    assetIds = @($asset.id)
    configuration = $configuration
  }
}

$fireTime = (Get-Date).ToUniversalTime()

$runErrors = @()
$runItems = @()
try {
  $runData = Invoke-GraphQL -Query $runMutation -Variables $runVariables -ToleratePartialData
  $runResult = if ($runData -and $runData.PSObject.Properties['assetsScriptRun']) { $runData.assetsScriptRun } else { $null }
  if ($runResult) {
    if ($runResult.PSObject.Properties['errors'] -and $runResult.errors) { $runErrors = @($runResult.errors) }
    if ($runResult.PSObject.Properties['items'] -and $runResult.items) { $runItems = @($runResult.items) }
  }
}
catch {
  Write-Host "    [note] Run request errored ($($_.Exception.Message)); will try to locate the run by name." -ForegroundColor Yellow
}

if ($runItems.Count -eq 0 -and $runErrors.Count -gt 0) {
  $detail = ($runErrors | ForEach-Object { $_.message }) -join '; '
  Write-Error "Script run was rejected: $detail"
  exit 1
}
foreach ($e in $runErrors) { Write-Host "    [warn] $($e.__typename): $($e.message)" -ForegroundColor Yellow }

$taskId = if ($runItems.Count -gt 0) { $runItems[0].id } else { $null }

Write-Success "Script run initiated!"
if ($taskId) { Write-Info "  Task ID:   $taskId" }
Write-Info "  Task Name: $effectiveName"
if (-not $taskId) { Write-Info "  (no task id returned — matching the run by name while polling)" }

# ===========================================================================
# STEP 5 — Poll until complete and gather the result
# ===========================================================================
Write-Step "Step 5: Gathering result (polling every ${PollIntervalSeconds}s, up to ${MaxWaitSeconds}s)..."

$execSearchQuery = @'
query PollExecutions($assetId: ID!) {
  asset(id: $assetId) {
    taskExecutionSearch(first: 25, orderBy: [{ field: STARTED_AT, direction: DESC }]) {
      nodes {
        id
        status
        exitCode
        errorMessage
        startedAt
        updatedAt
        durationMilliseconds
        task { id name }
        # The script's console output lives on the concrete ScriptTaskExecution
        # type (the base TaskExecution interface only exposes download/link).
        ... on ScriptTaskExecution {
          output {
            runAs
            stdOutput
            stdError
            outputs {
              name
              variable
              type
              value { stringValue booleanValue intValue floatValue dateTimeValue }
            }
          }
        }
      }
    }
  }
}
'@

$spinChars = '|', '/', '-', '\'
$spin = 0
$startTime = Get-Date
$timedOut = $false
$exec = $null

while ($true) {
  Start-Sleep -Seconds $PollIntervalSeconds
  $searchData = Invoke-GraphQL -Query $execSearchQuery -Variables @{ assetId = $asset.id } -ToleratePartialData

  $nodes = @()
  if ($searchData.asset -and $searchData.asset.PSObject.Properties['taskExecutionSearch'] -and
    $searchData.asset.taskExecutionSearch) {
    $nodes = @($searchData.asset.taskExecutionSearch.nodes)
  }
  # Identify our run: by task id when the mutation returned one; otherwise by task
  # name + start time (the transient "Internal error" path returns no id).
  $exec = $nodes | Where-Object {
    $_ -and $_.task -and (
      ($taskId -and $_.task.id -eq $taskId) -or
      (-not $taskId -and $_.task.name -eq $effectiveName -and $_.startedAt -and
        ([datetimeoffset]$_.startedAt).UtcDateTime -ge $fireTime.AddSeconds(-120))
    )
  } | Select-Object -First 1

  $elapsed = [int](New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds

  if ($exec) {
    Write-Host "`r    Finished in ${elapsed}s.                                        "
    break
  }

  Write-Host "`r    $($spinChars[$spin % 4]) Running on $($asset.name)...  (${elapsed}s elapsed)  " -NoNewline
  $spin++

  if ($elapsed -ge $MaxWaitSeconds) {
    Write-Host ""
    Write-Warning "No completed execution after ${elapsed}s. The run may still be in progress on the device."
    $timedOut = $true
    break
  }
}

# ===========================================================================
# Results
# ===========================================================================
$runStatus = if ($exec) { $exec.status } elseif ($timedOut) { 'PENDING' } else { 'UNKNOWN' }

$exitCodeDisplay = if ($exec -and $null -ne $exec.exitCode) { $exec.exitCode } else { 'N/A' }
$startedDisplay = if ($exec) { $exec.startedAt } else { 'N/A' }
$updatedDisplay = if ($exec) { $exec.updatedAt } else { 'N/A' }
$durationDisplay = if ($exec -and $null -ne $exec.durationMilliseconds) { "$([int]$exec.durationMilliseconds) ms" } else { 'N/A' }

$errText = if ($exec -and $exec.PSObject.Properties['errorMessage'] -and $exec.errorMessage) { $exec.errorMessage } else { '' }

$stdOut = ''
$stdErr = ''
$outputVars = @()
if ($exec -and $exec.PSObject.Properties['output'] -and $exec.output) {
  $scriptOutput = $exec.output
  if ($scriptOutput.PSObject.Properties['stdOutput'] -and $scriptOutput.stdOutput) { $stdOut = $scriptOutput.stdOutput }
  if ($scriptOutput.PSObject.Properties['stdError'] -and $scriptOutput.stdError) { $stdErr = $scriptOutput.stdError }
  if ($scriptOutput.PSObject.Properties['outputs'] -and $scriptOutput.outputs) { $outputVars = @($scriptOutput.outputs) }
}

Write-Host "`n========================================" -ForegroundColor White
Write-Host "  RESULT" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White

$statusColor = if ($runStatus -eq 'SUCCEEDED') { 'Green' }
elseif ($timedOut) { 'Yellow' }
else { 'Red' }

Write-Host "  Status:    " -NoNewline
Write-Host $runStatus -ForegroundColor $statusColor
Write-Host "  Device:    $($asset.name)"
Write-Host "  Script:    $($script.name)"
Write-Host "  Exit Code: $exitCodeDisplay"
Write-Host "  Duration:  $durationDisplay"
Write-Host "  Started:   $startedDisplay"
Write-Host "  Updated:   $updatedDisplay"

if ($outputVars.Count -gt 0) {
  Write-Host "`n  Output variables:" -ForegroundColor White
  foreach ($ov in $outputVars) {
    $v = $ov.value
    $shown = if ($v) {
      $v.stringValue, $v.booleanValue, $v.intValue, $v.floatValue, $v.dateTimeValue |
        Where-Object { $null -ne $_ } | Select-Object -First 1
    }
    else { '' }
    Write-Host "    - $($ov.variable) = $shown"
  }
}

if ($stdOut) {
  Write-Host "`n  ----- Script Output (stdout) --------------------" -ForegroundColor White
  Write-Host $stdOut
  Write-Host "  -------------------------------------------------" -ForegroundColor White
}

if ($stdErr) {
  Write-Host "`n  ----- Script Errors (stderr) --------------------" -ForegroundColor Red
  Write-Host $stdErr -ForegroundColor Red
  Write-Host "  -------------------------------------------------" -ForegroundColor Red
}

if ($errText) {
  Write-Host "`n  Execution error: $errText" -ForegroundColor Red
}

Write-Host "========================================`n" -ForegroundColor White

# Return a structured result for pipeline use
[PSCustomObject]@{
  TaskId = $taskId
  TaskName = $effectiveName
  Status = $runStatus
  ExitCode = if ($exec) { $exec.exitCode } else { $null }
  DurationMs = if ($exec) { $exec.durationMilliseconds } else { $null }
  StdOutput = $stdOut
  StdError = $stdErr
  ErrorMessage = $errText
  StartedAt = $startedDisplay
  UpdatedAt = $updatedDisplay
  DeviceName = $asset.name
  ScriptName = $script.name
  ExecutionId = if ($exec) { $exec.id } else { $null }
  TimedOut = $timedOut
}
