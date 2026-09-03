#Requires -Version 5.1
<#
  Install-OdooMCP.ps1
  One-click installer GUI for the Odoo MCP server (pantalytics/odoo-mcp-pro)
  for use with Claude Desktop. Installs a standalone Python (no admin rights
  needed), installs portable Git if required, installs the MCP server
  package, tests the Odoo connection with the credentials you enter, and
  writes/merges the claude_desktop_config.json entry.

  All installable logic lives in OdooMcpInstaller.psm1 (kept separate from
  this GUI so it can be unit- and integration-tested with Pester -- see
  tests/OdooMcpInstaller.Tests.ps1).
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-Module (Join-Path $PSScriptRoot "OdooMcpInstaller.psm1") -Force

$PythonDir  = "$env:LOCALAPPDATA\Programs\PythonEmbed312"
$PythonExe  = "$PythonDir\python.exe"
$ConfigPath = "$env:APPDATA\Claude\claude_desktop_config.json"
$GitDir     = "$env:LOCALAPPDATA\Programs\MinGit"
$GitCmdDir  = "$GitDir\cmd"

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

Set-InstallerLogger -Action {
    param($Message)
    $LogBox.AppendText("$Message`r`n")
    $LogBox.SelectionStart = $LogBox.Text.Length
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

$DetectBtn.Add_Click({
    if (-not $UrlBox.Text) { Write-InstallerLog "Enter the Odoo URL first."; return }
    Install-Python -PythonExe $PythonExe -PythonDir $PythonDir
    Write-InstallerLog "Looking up databases on $($UrlBox.Text)..."
    $dbs = Get-OdooDbList -PythonExe $PythonExe -Url $UrlBox.Text.TrimEnd('/')
    if ($dbs.Count -eq 0) {
        Write-InstallerLog "No databases returned (endpoint may be disabled). Enter the DB name manually."
    } elseif ($dbs.Count -eq 1) {
        $DbBox.Text = $dbs[0]
        Write-InstallerLog "Detected database: $($dbs[0])"
    } else {
        Write-InstallerLog "Multiple databases found: $($dbs -join ', ')"
        Write-InstallerLog "Enter the correct one manually in the Database field."
    }
})

$TestBtn.Add_Click({
    if (-not $UrlBox.Text -or -not $KeyBox.Text) { Write-InstallerLog "URL and API key are required."; return }
    Install-Python -PythonExe $PythonExe -PythonDir $PythonDir
    Write-InstallerLog "Testing connection..."
    $result = Test-OdooConnection -PythonExe $PythonExe -Url $UrlBox.Text.TrimEnd('/') -ApiKey $KeyBox.Text -User $UserBox.Text -Database $DbBox.Text
    if ($result.Ok) { Write-InstallerLog "SUCCESS: $($result.Detail)" }
    else { Write-InstallerLog "FAILED: $($result.Detail)" }
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
        Install-Python -PythonExe $PythonExe -PythonDir $PythonDir
        Install-OdooPackage -PythonExe $PythonExe -GitDir $GitDir -GitCmdDir $GitCmdDir
        Write-InstallerLog "Verifying credentials before saving..."
        $result = Test-OdooConnection -PythonExe $PythonExe -Url $UrlBox.Text.TrimEnd('/') -ApiKey $KeyBox.Text -User $UserBox.Text -Database $DbBox.Text
        if (-not $result.Ok) {
            Write-InstallerLog "FAILED: $($result.Detail)"
            [System.Windows.Forms.MessageBox]::Show("Connection test failed:`r`n$($result.Detail)`r`n`r`nConfig was NOT saved. Fix the fields and try again.", "Connection failed") | Out-Null
            return
        }
        Write-InstallerLog "SUCCESS: $($result.Detail)"
        Save-Config -ConfigPath $ConfigPath -PythonExe $PythonExe -Url $UrlBox.Text.TrimEnd('/') -ApiKey $KeyBox.Text -User $UserBox.Text -Database $DbBox.Text | Out-Null
        Write-InstallerLog ""
        Write-InstallerLog "DONE. Fully quit and reopen Claude Desktop to load the odoo MCP server."
        [System.Windows.Forms.MessageBox]::Show("Installed and verified successfully.`r`n`r`nFully quit and reopen Claude Desktop now.", "Done") | Out-Null
    } catch {
        Write-InstallerLog "ERROR: $_"
        [System.Windows.Forms.MessageBox]::Show("Install failed: $_", "Error") | Out-Null
    } finally {
        $InstallBtn.Enabled = $true
        $TestBtn.Enabled = $true
        $DetectBtn.Enabled = $true
    }
})

[void]$Form.ShowDialog()
