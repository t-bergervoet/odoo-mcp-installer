#Requires -Version 5.1
<#
  Install-OdooMCP.ps1
  One-click installer for the Odoo MCP server (pantalytics/odoo-mcp-pro)
  for use with Claude Desktop. Installs a standalone Python (no admin
  rights needed), installs the MCP server package, tests the Odoo
  connection with the credentials you enter, and writes/merges the
  claude_desktop_config.json entry.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$PythonDir = "$env:LOCALAPPDATA\Programs\PythonEmbed312"
$PythonExe = "$PythonDir\python.exe"
$ConfigPath = "$env:APPDATA\Claude\claude_desktop_config.json"
$PythonVersion = "3.12.10"
$GitDir = "$env:LOCALAPPDATA\Programs\MinGit"
$GitCmdDir = "$GitDir\cmd"

# ---------- Helpers ----------

function ConvertTo-Hashtable {
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

function Write-Log {
    param([string]$Message)
    $LogBox.AppendText("$Message`r`n")
    $LogBox.SelectionStart = $LogBox.Text.Length
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Install-Python {
    if (Test-Path $PythonExe) {
        Write-Log "Python already installed at $PythonDir"
        return
    }
    Write-Log "Downloading Python $PythonVersion (embeddable)..."
    New-Item -ItemType Directory -Force -Path $PythonDir | Out-Null
    $zip = "$env:TEMP\python-embed-$PythonVersion.zip"
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $PythonDir -Force
    Remove-Item -Force -ErrorAction SilentlyContinue $zip

    $pthFile = Get-ChildItem "$PythonDir\python3*._pth" | Select-Object -First 1
    (Get-Content $pthFile.FullName) -replace '#import site', 'import site' | Set-Content $pthFile.FullName

    Write-Log "Bootstrapping pip..."
    $getpip = "$env:TEMP\get-pip.py"
    Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $getpip
    & $PythonExe $getpip *>> $null
    Remove-Item -Force -ErrorAction SilentlyContinue $getpip
    Write-Log "Python ready."
}

function Install-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Log "System git found, using it."
        return
    }
    if (Test-Path "$GitCmdDir\git.exe") {
        Write-Log "Portable Git already installed at $GitDir"
        if ($env:PATH -notlike "*$GitCmdDir*") { $env:PATH = "$GitCmdDir;$env:PATH" }
        return
    }
    Write-Log "Git not found. Downloading portable MinGit (no admin rights needed)..."
    New-Item -ItemType Directory -Force -Path $GitDir | Out-Null

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -Headers @{ "User-Agent" = "odoo-mcp-installer" }
    $asset = $release.assets | Where-Object { $_.name -match "^MinGit-.*-64-bit\.zip$" } | Select-Object -First 1
    if (-not $asset) { throw "Could not find a MinGit release asset to download." }

    $zip = "$env:TEMP\$($asset.name)"
    Write-Log "Downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $GitDir -Force
    Remove-Item -Force -ErrorAction SilentlyContinue $zip

    if (-not (Test-Path "$GitCmdDir\git.exe")) { throw "MinGit extraction did not produce cmd\git.exe as expected." }
    $env:PATH = "$GitCmdDir;$env:PATH"
    Write-Log "Portable Git ready."
}

function Install-OdooPackage {
    $installed = & $PythonExe -m pip show mcp-server-odoo 2>$null
    if ($installed) {
        Write-Log "mcp-server-odoo already installed."
        return
    }
    Install-Git
    Write-Log "Installing build tools..."
    & $PythonExe -m pip install --quiet hatchling hatch-vcs 2>&1 | ForEach-Object { Write-Log $_ }
    Write-Log "Installing mcp-server-odoo from GitHub (this can take a minute)..."
    & $PythonExe -m pip install --quiet --no-build-isolation "mcp-server-odoo @ git+https://github.com/pantalytics/odoo-mcp-pro.git" 2>&1 | ForEach-Object { Write-Log $_ }
    Write-Log "Package installed."
}

function Test-OdooConnection {
    param($Url, $ApiKey, $User, $Db)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PythonExe
    $psi.Arguments = "-m mcp_server_odoo"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables["ODOO_URL"] = $Url
    $psi.EnvironmentVariables["ODOO_API_KEY"] = $ApiKey
    if ($User) { $psi.EnvironmentVariables["ODOO_USER"] = $User }
    if ($Db)   { $psi.EnvironmentVariables["ODOO_DB"] = $Db }

    $p = [System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Seconds 6
    $stderr = $p.StandardError.ReadToEnd()
    try { $p.Kill() } catch {}

    if ($stderr -match "Successfully authenticated") {
        return @{ Ok = $true; Detail = "Authenticated successfully." }
    }
    if ($stderr -match "database\s+`"([^`"]+)`"\s+does not exist") {
        return @{ Ok = $false; Detail = "Database '$($Matches[1])' does not exist. Set the correct ODOO_DB." }
    }
    if ($stderr -match "Username required") {
        return @{ Ok = $false; Detail = "Odoo requires a username with the API key. Fill in the Username field." }
    }
    if ($stderr -match "Authentication failed") {
        return @{ Ok = $false; Detail = "Authentication failed. Check the URL, API key, username and database." }
    }
    return @{ Ok = $false; Detail = "Unexpected output:`r`n$stderr" }
}

function Get-OdooDbList {
    param($Url)
    try {
        $code = "import xmlrpc.client,sys; print('|'.join(xmlrpc.client.ServerProxy('$Url/xmlrpc/2/db').list()))"
        $result = & $PythonExe -c $code 2>$null
        if ($LASTEXITCODE -eq 0 -and $result) { return $result -split '\|' }
    } catch {}
    return @()
}

function Save-Config {
    param($Url, $ApiKey, $User, $Db)

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
            Write-Log "WARNING: existing config was invalid JSON, replacing it."
        }
    }
    if (-not $config) { $config = @{} }
    if (-not $config.ContainsKey("mcpServers")) { $config["mcpServers"] = @{} }

    $envBlock = @{
        ODOO_URL     = $Url
        ODOO_API_KEY = $ApiKey
    }
    if ($User) { $envBlock["ODOO_USER"] = $User }
    if ($Db)   { $envBlock["ODOO_DB"] = $Db }

    $config["mcpServers"]["odoo"] = @{
        command = $PythonExe
        args    = @("-m", "mcp_server_odoo")
        env     = $envBlock
    }

    $config | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 $ConfigPath
    Write-Log "Config written to $ConfigPath"
}

# ---------- GUI ----------

$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Odoo MCP Installer"
$Form.Size = New-Object System.Drawing.Size(560, 560)
$Form.StartPosition = "CenterScreen"
$Form.FormBorderStyle = "FixedDialog"
$Form.MaximizeBox = $false

function Add-Label($text, $y) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.Location = New-Object System.Drawing.Point(20, $y)
    $lbl.Size = New-Object System.Drawing.Size(520, 20)
    $Form.Controls.Add($lbl)
}

function Add-TextBox($y, $isPassword) {
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(20, $y)
    $tb.Size = New-Object System.Drawing.Size(510, 24)
    if ($isPassword) { $tb.UseSystemPasswordChar = $true }
    $Form.Controls.Add($tb)
    return $tb
}

Add-Label "Odoo URL (e.g. https://mycompany.odoo.com)" 10
$UrlBox = Add-TextBox 30 $false

Add-Label "Odoo API Key" 62
$KeyBox = Add-TextBox 82 $true

Add-Label "Odoo Username / login email (required if API key alone is rejected)" 114
$UserBox = Add-TextBox 134 $false

Add-Label "Database name (leave blank to auto-detect)" 166
$DbBox = Add-TextBox 186 $false

$DetectBtn = New-Object System.Windows.Forms.Button
$DetectBtn.Text = "Auto-detect DB"
$DetectBtn.Location = New-Object System.Drawing.Point(20, 216)
$DetectBtn.Size = New-Object System.Drawing.Size(140, 28)
$Form.Controls.Add($DetectBtn)

$TestBtn = New-Object System.Windows.Forms.Button
$TestBtn.Text = "Test Connection"
$TestBtn.Location = New-Object System.Drawing.Point(170, 216)
$TestBtn.Size = New-Object System.Drawing.Size(140, 28)
$Form.Controls.Add($TestBtn)

$InstallBtn = New-Object System.Windows.Forms.Button
$InstallBtn.Text = "Install"
$InstallBtn.Location = New-Object System.Drawing.Point(320, 216)
$InstallBtn.Size = New-Object System.Drawing.Size(210, 28)
$InstallBtn.Font = New-Object System.Drawing.Font($InstallBtn.Font, [System.Drawing.FontStyle]::Bold)
$Form.Controls.Add($InstallBtn)

$LogBox = New-Object System.Windows.Forms.TextBox
$LogBox.Location = New-Object System.Drawing.Point(20, 256)
$LogBox.Size = New-Object System.Drawing.Size(510, 260)
$LogBox.Multiline = $true
$LogBox.ScrollBars = "Vertical"
$LogBox.ReadOnly = $true
$LogBox.Font = New-Object System.Drawing.Font("Consolas", 8.5)
$Form.Controls.Add($LogBox)

$DetectBtn.Add_Click({
    if (-not $UrlBox.Text) { Write-Log "Enter the Odoo URL first."; return }
    Install-Python
    Write-Log "Looking up databases on $($UrlBox.Text)..."
    $dbs = Get-OdooDbList -Url $UrlBox.Text.TrimEnd('/')
    if ($dbs.Count -eq 0) {
        Write-Log "No databases returned (endpoint may be disabled). Enter the DB name manually."
    } elseif ($dbs.Count -eq 1) {
        $DbBox.Text = $dbs[0]
        Write-Log "Detected database: $($dbs[0])"
    } else {
        Write-Log "Multiple databases found: $($dbs -join ', ')"
        Write-Log "Enter the correct one manually in the Database field."
    }
})

$TestBtn.Add_Click({
    if (-not $UrlBox.Text -or -not $KeyBox.Text) { Write-Log "URL and API key are required."; return }
    Install-Python
    Write-Log "Testing connection..."
    $result = Test-OdooConnection -Url $UrlBox.Text.TrimEnd('/') -ApiKey $KeyBox.Text -User $UserBox.Text -Db $DbBox.Text
    if ($result.Ok) { Write-Log "SUCCESS: $($result.Detail)" }
    else { Write-Log "FAILED: $($result.Detail)" }
})

$InstallBtn.Add_Click({
    if (-not $UrlBox.Text -or -not $KeyBox.Text) {
        [System.Windows.Forms.MessageBox]::Show("Odoo URL and API key are required.", "Missing info") | Out-Null
        return
    }
    $InstallBtn.Enabled = $false
    $TestBtn.Enabled = $false
    $DetectBtn.Enabled = $false
    try {
        Install-Python
        Install-OdooPackage
        Write-Log "Verifying credentials before saving..."
        $result = Test-OdooConnection -Url $UrlBox.Text.TrimEnd('/') -ApiKey $KeyBox.Text -User $UserBox.Text -Db $DbBox.Text
        if (-not $result.Ok) {
            Write-Log "FAILED: $($result.Detail)"
            [System.Windows.Forms.MessageBox]::Show("Connection test failed:`r`n$($result.Detail)`r`n`r`nConfig was NOT saved. Fix the fields and try again.", "Connection failed") | Out-Null
            return
        }
        Write-Log "SUCCESS: $($result.Detail)"
        Save-Config -Url $UrlBox.Text.TrimEnd('/') -ApiKey $KeyBox.Text -User $UserBox.Text -Db $DbBox.Text
        Write-Log ""
        Write-Log "DONE. Fully quit and reopen Claude Desktop to load the odoo MCP server."
        [System.Windows.Forms.MessageBox]::Show("Installed and verified successfully.`r`n`r`nFully quit and reopen Claude Desktop now.", "Done") | Out-Null
    } catch {
        Write-Log "ERROR: $_"
        [System.Windows.Forms.MessageBox]::Show("Install failed: $_", "Error") | Out-Null
    } finally {
        $InstallBtn.Enabled = $true
        $TestBtn.Enabled = $true
        $DetectBtn.Enabled = $true
    }
})

[void]$Form.ShowDialog()
