<#
  OdooMcpInstaller.psm1
  Core logic for the Odoo MCP installer, separated from the GUI (Install-OdooMCP.ps1)
  so it can be unit- and integration-tested with Pester independent of any UI.
#>

Add-Type -AssemblyName System.Windows.Forms

$script:LogAction = { param($Message) Write-Host $Message }

function Set-InstallerLogger {
    <# Redirect log output somewhere other than the console (e.g. a WinForms textbox). #>
    param([Parameter(Mandatory)][scriptblock]$Action)
    $script:LogAction = $Action
}

function Write-InstallerLog {
    param([string]$Message)
    & $script:LogAction $Message
}

function ConvertTo-Hashtable {
    <# Recursively converts ConvertFrom-Json's PSCustomObject output into nested
       Hashtables/arrays, since PowerShell 5.1's ConvertFrom-Json lacks -AsHashtable. #>
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = @()
        foreach ($item in $InputObject) { $list += ,(ConvertTo-Hashtable $item) }
        return $list
    }
    if ($InputObject -is [psobject]) {
        $hash = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-Hashtable $prop.Value
        }
        return $hash
    }
    return $InputObject
}

function Get-ConnectionResult {
    <# Pure function: classifies mcp_server_odoo's combined stdout+stderr text
       into a pass/fail result with a human-readable reason. Kept separate from
       process-spawning so it can be unit tested with canned text. #>
    param([string]$OutputText)

    if ($OutputText -match "Successfully authenticated") {
        return @{ Ok = $true; Detail = "Authenticated successfully." }
    }
    if ($OutputText -match 'database\s+"([^"]+)"\s+does not exist') {
        return @{ Ok = $false; Detail = "Database '$($Matches[1])' does not exist. Set the correct ODOO_DB." }
    }
    if ($OutputText -match "Username required") {
        return @{ Ok = $false; Detail = "Odoo requires a username with the API key. Fill in the Username field." }
    }
    if ($OutputText -match "Authentication failed") {
        return @{ Ok = $false; Detail = "Authentication failed. Check the URL, API key, username and database." }
    }
    return @{ Ok = $false; Detail = "Unexpected output:`r`n$OutputText" }
}

function ConvertFrom-DbListOutput {
    <# Pure function: parses the pipe-delimited output of the db-list probe. #>
    param([string]$RawOutput)
    if (-not $RawOutput) { return @() }
    return @($RawOutput -split '\|' | Where-Object { $_ })
}

function Install-Python {
    param(
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$PythonDir,
        [string]$PythonVersion = "3.12.10"
    )
    if (Test-Path $PythonExe) {
        Write-InstallerLog "Python already installed at $PythonDir"
        return
    }
    Write-InstallerLog "Downloading Python $PythonVersion (embeddable)..."
    New-Item -ItemType Directory -Force -Path $PythonDir | Out-Null
    $zip = "$env:TEMP\python-embed-$PythonVersion-$([guid]::NewGuid().ToString('N')).zip"
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $PythonDir -Force
    Remove-Item -Force -ErrorAction SilentlyContinue $zip

    $pthFile = Get-ChildItem "$PythonDir\python3*._pth" | Select-Object -First 1
    if (-not $pthFile) { throw "Could not find the extracted Python's ._pth file." }
    (Get-Content $pthFile.FullName) -replace '#import site', 'import site' | Set-Content $pthFile.FullName

    if (-not (Test-Path $PythonExe)) { throw "Python extraction did not produce $PythonExe as expected." }

    Write-InstallerLog "Bootstrapping pip..."
    $getpip = "$env:TEMP\get-pip-$([guid]::NewGuid().ToString('N')).py"
    Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $getpip
    & $PythonExe $getpip *>> $null
    Remove-Item -Force -ErrorAction SilentlyContinue $getpip
    Write-InstallerLog "Python ready."
}

function Install-Git {
    param(
        [Parameter(Mandatory)][string]$GitDir,
        [Parameter(Mandatory)][string]$GitCmdDir
    )
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-InstallerLog "System git found, using it."
        return
    }
    if (Test-Path "$GitCmdDir\git.exe") {
        Write-InstallerLog "Portable Git already installed at $GitDir"
        if ($env:PATH -notlike "*$GitCmdDir*") { $env:PATH = "$GitCmdDir;$env:PATH" }
        return
    }
    Write-InstallerLog "Git not found. Downloading portable MinGit (no admin rights needed)..."
    New-Item -ItemType Directory -Force -Path $GitDir | Out-Null

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -Headers @{ "User-Agent" = "odoo-mcp-installer" }
    $asset = $release.assets | Where-Object { $_.name -match "^MinGit-.*-64-bit\.zip$" } | Select-Object -First 1
    if (-not $asset) { throw "Could not find a MinGit release asset to download." }

    $zip = "$env:TEMP\$($asset.name)"
    Write-InstallerLog "Downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $GitDir -Force
    Remove-Item -Force -ErrorAction SilentlyContinue $zip

    if (-not (Test-Path "$GitCmdDir\git.exe")) { throw "MinGit extraction did not produce cmd\git.exe as expected." }
    $env:PATH = "$GitCmdDir;$env:PATH"
    Write-InstallerLog "Portable Git ready."
}

function Install-OdooPackage {
    param(
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$GitDir,
        [Parameter(Mandatory)][string]$GitCmdDir
    )
    $installed = & $PythonExe -m pip show mcp-server-odoo 2>$null
    if ($installed) {
        Write-InstallerLog "mcp-server-odoo already installed."
        return
    }
    Install-Git -GitDir $GitDir -GitCmdDir $GitCmdDir
    Write-InstallerLog "Installing build tools..."
    & $PythonExe -m pip install --quiet hatchling hatch-vcs 2>&1 | ForEach-Object { Write-InstallerLog $_ }
    Write-InstallerLog "Installing mcp-server-odoo from GitHub (this can take a minute)..."
    & $PythonExe -m pip install --quiet --no-build-isolation "mcp-server-odoo @ git+https://github.com/pantalytics/odoo-mcp-pro.git" 2>&1 | ForEach-Object { Write-InstallerLog $_ }

    $installed = & $PythonExe -m pip show mcp-server-odoo 2>$null
    if (-not $installed) { throw "mcp-server-odoo did not report as installed after pip install." }
    Write-InstallerLog "Package installed."
}

function Test-OdooConnection {
    <#
      Spawns the MCP server with the given credentials and classifies the result.

      IMPORTANT: on successful auth, mcp_server_odoo stays running (waiting on
      stdio), so its stderr pipe never closes. Reading it with ReadToEnd() would
      block forever. Instead we read asynchronously into a buffer and poll it,
      killing the process as soon as we see a conclusive result (or after a
      timeout) rather than waiting for the pipe to close.
    #>
    param(
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ApiKey,
        [string]$User,
        [string]$Database,
        [int]$TimeoutMs = 12000
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PythonExe
    $psi.Arguments = "-m mcp_server_odoo"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables["ODOO_URL"] = $Url
    $psi.EnvironmentVariables["ODOO_API_KEY"] = $ApiKey
    if ($User) { $psi.EnvironmentVariables["ODOO_USER"] = $User }
    if ($Database)   { $psi.EnvironmentVariables["ODOO_DB"] = $Database }

    $sb = New-Object System.Text.StringBuilder
    $lock = New-Object object

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $p.EnableRaisingEvents = $true
    $handler = {
        if ($null -ne $EventArgs.Data) {
            [System.Threading.Monitor]::Enter($Event.MessageData.Lock)
            try { [void]$Event.MessageData.Sb.AppendLine($EventArgs.Data) }
            finally { [System.Threading.Monitor]::Exit($Event.MessageData.Lock) }
        }
    }
    $md = @{ Sb = $sb; Lock = $lock }
    Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action $handler -MessageData $md | Out-Null
    Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -Action $handler -MessageData $md | Out-Null

    try {
        [void]$p.Start()
        $p.BeginOutputReadLine()
        $p.BeginErrorReadLine()

        $elapsed = 0
        $intervalMs = 250
        $text = ""
        $matched = $false
        $pattern = 'Successfully authenticated|Authentication failed|database\s+"[^"]+"\s+does not exist|Username required'

        while ($elapsed -lt $TimeoutMs) {
            Start-Sleep -Milliseconds $intervalMs
            $elapsed += $intervalMs
            [System.Threading.Monitor]::Enter($lock)
            try { $text = $sb.ToString() } finally { [System.Threading.Monitor]::Exit($lock) }
            if ($text -match $pattern) { $matched = $true; break }
            if ($p.HasExited) { break }
            [System.Windows.Forms.Application]::DoEvents()
        }

        if (-not $matched) {
            # Give any final buffered output a moment to flush after exit/timeout.
            Start-Sleep -Milliseconds 300
            [System.Threading.Monitor]::Enter($lock)
            try { $text = $sb.ToString() } finally { [System.Threading.Monitor]::Exit($lock) }
        }

        return Get-ConnectionResult -OutputText $text
    }
    finally {
        try { if (-not $p.HasExited) { $p.Kill() } } catch {}
        try { $p.WaitForExit(3000) | Out-Null } catch {}
        Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object { $_.SourceObject -eq $p } | Unregister-Event -ErrorAction SilentlyContinue
        $p.Dispose()
    }
}

function Get-OdooDbList {
    param(
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$Url
    )
    try {
        $code = "import xmlrpc.client,sys; print('|'.join(xmlrpc.client.ServerProxy('$Url/xmlrpc/2/db').list()))"
        $result = & $PythonExe -c $code 2>$null
        if ($LASTEXITCODE -eq 0 -and $result) { return ConvertFrom-DbListOutput -RawOutput $result }
    } catch {}
    return @()
}

function Save-Config {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ApiKey,
        [string]$User,
        [string]$Database
    )

    New-Item -ItemType Directory -Force -Path (Split-Path $ConfigPath) | Out-Null

    $config = @{}
    if (Test-Path $ConfigPath) {
        try {
            $raw = Get-Content $ConfigPath -Raw
            if ($raw.Trim()) {
                $parsed = $raw | ConvertFrom-Json
                $config = ConvertTo-Hashtable $parsed
            }
        } catch {
            Write-InstallerLog "WARNING: existing config was invalid JSON, replacing it."
        }
    }
    if (-not $config) { $config = @{} }
    if (-not $config.ContainsKey("mcpServers")) { $config["mcpServers"] = @{} }

    $envBlock = @{
        ODOO_URL     = $Url
        ODOO_API_KEY = $ApiKey
    }
    if ($User) { $envBlock["ODOO_USER"] = $User }
    if ($Database)   { $envBlock["ODOO_DB"] = $Database }

    $config["mcpServers"]["odoo"] = @{
        command = $PythonExe
        args    = @("-m", "mcp_server_odoo")
        env     = $envBlock
    }

    $config | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 $ConfigPath
    Write-InstallerLog "Config written to $ConfigPath"
    return $config
}

Export-ModuleMember -Function *
