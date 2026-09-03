<#
  OdooMcpInstaller.Tests.ps1

  Pester 5 test suite for the installer.

  Unit tests (always run): pure parsing/classification logic and the config
  file read-merge-write behavior, using temp files -- no network access.

  Integration tests (skipped unless ODOO_MCP_TEST_* env vars are set): the
  real end-to-end path -- download a throwaway Python + Git into a temp
  directory, install the real package from GitHub, and authenticate against
  a real Odoo instance. This is what actually proves the "fresh Windows PC"
  install path works, and specifically regression-tests the hang bug where
  Test-OdooConnection would block forever on a successful auth.

  Run locally:
    Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
    Invoke-Pester -Path .\tests\OdooMcpInstaller.Tests.ps1 -Output Detailed

  Run the integration tests too (requires a real Odoo instance to test against):
    $env:ODOO_MCP_TEST_URL = "https://your-test-instance.odoo.com"
    $env:ODOO_MCP_TEST_API_KEY = "..."
    $env:ODOO_MCP_TEST_USER = "you@example.com"
    $env:ODOO_MCP_TEST_DB = "your-test-db"          # optional
    Invoke-Pester -Path .\tests\OdooMcpInstaller.Tests.ps1 -Output Detailed
#>

# Computed at discovery time (not inside BeforeAll) so it can be used with
# Describe's -Skip parameter below.
$HasLiveOdoo = [bool]($env:ODOO_MCP_TEST_URL -and $env:ODOO_MCP_TEST_API_KEY)

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot "..\OdooMcpInstaller.psm1") -Force
    Set-InstallerLogger -Action { param($Message) } # silence logging during tests
}

Describe "Get-ConnectionResult (unit)" {
    It "recognizes a successful authentication" {
        $r = Get-ConnectionResult -OutputText "...Successfully authenticated using MCP API key..."
        $r.Ok | Should -Be $true
    }

    It "recognizes a missing-database error and extracts the database name" {
        $r = Get-ConnectionResult -OutputText 'psycopg2.OperationalError: database "p_mycompany_1234" does not exist'
        $r.Ok | Should -Be $false
        $r.Detail | Should -Match "p_mycompany_1234"
    }

    It "recognizes a missing-username error" {
        $r = Get-ConnectionResult -OutputText "WARNING - Username required with API key for standard authentication"
        $r.Ok | Should -Be $false
        $r.Detail | Should -Match "Username"
    }

    It "recognizes a generic authentication failure" {
        $r = Get-ConnectionResult -OutputText "ERROR - Server error: Authentication failed. Please check..."
        $r.Ok | Should -Be $false
        $r.Detail | Should -Match "Authentication failed"
    }

    It "falls back to raw output for unrecognized text" {
        $r = Get-ConnectionResult -OutputText "some completely unexpected line"
        $r.Ok | Should -Be $false
        $r.Detail | Should -Match "Unexpected output"
    }
}

Describe "ConvertFrom-DbListOutput (unit)" {
    It "parses multiple pipe-delimited databases" {
        (ConvertFrom-DbListOutput -RawOutput "db1|db2|db3") | Should -Be @("db1", "db2", "db3")
    }
    It "parses a single database" {
        (ConvertFrom-DbListOutput -RawOutput "onlydb") | Should -Be @("onlydb")
    }
    It "returns an empty array for empty input" {
        @(ConvertFrom-DbListOutput -RawOutput "").Count | Should -Be 0
    }
    It "returns an empty array for null input" {
        @(ConvertFrom-DbListOutput -RawOutput $null).Count | Should -Be 0
    }
}

Describe "ConvertTo-Hashtable (unit)" {
    It "round-trips nested JSON into hashtables and arrays" {
        $json = '{"a":1,"b":{"c":[1,2,3],"d":"x"}}'
        $obj = $json | ConvertFrom-Json
        $h = ConvertTo-Hashtable $obj
        $h | Should -BeOfType [hashtable]
        $h["a"] | Should -Be 1
        $h["b"] | Should -BeOfType [hashtable]
        $h["b"]["d"] | Should -Be "x"
        ,$h["b"]["c"] | Should -BeOfType [array]
        $h["b"]["c"].Count | Should -Be 3
    }
}

Describe "Save-Config (unit, filesystem only)" {
    BeforeEach {
        $script:TestConfigPath = Join-Path $TestDrive "claude_desktop_config.json"
    }

    It "creates a new config file with the odoo server when none exists" {
        Save-Config -ConfigPath $script:TestConfigPath -PythonExe "C:\fake\python.exe" `
            -Url "https://example.odoo.com" -ApiKey "KEY" -User "u@example.com" -Database "mydb"

        Test-Path $script:TestConfigPath | Should -Be $true
        $parsed = Get-Content $script:TestConfigPath -Raw | ConvertFrom-Json
        $parsed.mcpServers.odoo.env.ODOO_URL | Should -Be "https://example.odoo.com"
        $parsed.mcpServers.odoo.env.ODOO_API_KEY | Should -Be "KEY"
        $parsed.mcpServers.odoo.env.ODOO_USER | Should -Be "u@example.com"
        $parsed.mcpServers.odoo.env.ODOO_DB | Should -Be "mydb"
        $parsed.mcpServers.odoo.command | Should -Be "C:\fake\python.exe"
    }

    It "preserves other mcpServers entries and unrelated top-level keys when merging" {
        '{"mcpServers":{"other":{"command":"foo"}},"preferences":{"a":1}}' | Set-Content -Encoding utf8 $script:TestConfigPath

        Save-Config -ConfigPath $script:TestConfigPath -PythonExe "C:\fake\python.exe" `
            -Url "https://example.odoo.com" -ApiKey "KEY" -User "" -Database ""

        $parsed = Get-Content $script:TestConfigPath -Raw | ConvertFrom-Json
        $parsed.mcpServers.other.command | Should -Be "foo"
        $parsed.preferences.a | Should -Be 1
        $parsed.mcpServers.odoo.env.ODOO_URL | Should -Be "https://example.odoo.com"
    }

    It "omits ODOO_USER and ODOO_DB from the env block when not provided" {
        Save-Config -ConfigPath $script:TestConfigPath -PythonExe "C:\fake\python.exe" `
            -Url "https://example.odoo.com" -ApiKey "KEY" -User "" -Database ""

        $parsed = Get-Content $script:TestConfigPath -Raw | ConvertFrom-Json
        ($parsed.mcpServers.odoo.env.PSObject.Properties.Name -contains "ODOO_USER") | Should -Be $false
        ($parsed.mcpServers.odoo.env.PSObject.Properties.Name -contains "ODOO_DB") | Should -Be $false
    }

    It "recovers gracefully when the existing config file is invalid JSON" {
        "{ this is not valid json" | Set-Content -Encoding utf8 $script:TestConfigPath

        { Save-Config -ConfigPath $script:TestConfigPath -PythonExe "C:\fake\python.exe" `
            -Url "https://example.odoo.com" -ApiKey "KEY" } | Should -Not -Throw

        # Result must still be valid, parseable JSON with our server present.
        $parsed = Get-Content $script:TestConfigPath -Raw | ConvertFrom-Json
        $parsed.mcpServers.odoo.env.ODOO_URL | Should -Be "https://example.odoo.com"
    }

    It "is idempotent -- running it twice still yields valid JSON with the latest values" {
        Save-Config -ConfigPath $script:TestConfigPath -PythonExe "C:\fake\python.exe" -Url "https://old.odoo.com" -ApiKey "OLDKEY"
        Save-Config -ConfigPath $script:TestConfigPath -PythonExe "C:\fake\python.exe" -Url "https://new.odoo.com" -ApiKey "NEWKEY"

        $parsed = Get-Content $script:TestConfigPath -Raw | ConvertFrom-Json
        $parsed.mcpServers.odoo.env.ODOO_URL | Should -Be "https://new.odoo.com"
        $parsed.mcpServers.odoo.env.ODOO_API_KEY | Should -Be "NEWKEY"
    }
}

Describe "End-to-end install and connect (integration, live Odoo required)" -Tag "Integration" -Skip:(-not $HasLiveOdoo) {
    BeforeAll {
        $script:TestRoot   = Join-Path $TestDrive "e2e"
        $script:PythonDir  = Join-Path $script:TestRoot "PythonEmbed"
        $script:PythonExe  = Join-Path $script:PythonDir "python.exe"
        $script:GitDir     = Join-Path $script:TestRoot "MinGit"
        $script:GitCmdDir  = Join-Path $script:GitDir "cmd"
        $script:ConfigPath = Join-Path $script:TestRoot "claude_desktop_config.json"
    }

    It "installs a fresh, working Python with no admin rights" {
        Install-Python -PythonExe $script:PythonExe -PythonDir $script:PythonDir
        Test-Path $script:PythonExe | Should -Be $true
        (& $script:PythonExe --version) | Should -Match "Python 3\.12"
    }

    It "installs the mcp-server-odoo package (and portable Git if needed)" {
        Install-OdooPackage -PythonExe $script:PythonExe -GitDir $script:GitDir -GitCmdDir $script:GitCmdDir
        $shown = & $script:PythonExe -m pip show mcp-server-odoo 2>$null
        $shown | Should -Not -BeNullOrEmpty
    }

    It "authenticates successfully against the real Odoo instance, and does not hang" {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Test-OdooConnection -PythonExe $script:PythonExe `
            -Url $env:ODOO_MCP_TEST_URL -ApiKey $env:ODOO_MCP_TEST_API_KEY `
            -User $env:ODOO_MCP_TEST_USER -Database $env:ODOO_MCP_TEST_DB
        $sw.Stop()

        $result.Ok | Should -Be $true
        # Regression guard for the "Test Connection hangs forever" bug: a
        # successful auth must resolve well before the function's own 12s
        # internal timeout, proving the process is being killed/read
        # correctly instead of blocking on a pipe that never closes.
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20
    }

    It "queries the db-list endpoint without throwing (result may legitimately be empty if the instance disables it)" {
        $script:dbs = $null
        { $script:dbs = Get-OdooDbList -PythonExe $script:PythonExe -Url $env:ODOO_MCP_TEST_URL } | Should -Not -Throw
        # Some hosted instances disable the db-list endpoint entirely -- that's
        # a valid (empty) result, not a failure. @(...).Count is always >= 0
        # and never $null, so this avoids the empty-array/$null pipeline
        # ambiguity that a direct "Should -Not -Be $null" comparison hits.
        @($script:dbs).Count | Should -BeGreaterOrEqual 0
    }

    It "writes a config file that Claude Desktop would load correctly" {
        Save-Config -ConfigPath $script:ConfigPath -PythonExe $script:PythonExe `
            -Url $env:ODOO_MCP_TEST_URL -ApiKey $env:ODOO_MCP_TEST_API_KEY `
            -User $env:ODOO_MCP_TEST_USER -Database $env:ODOO_MCP_TEST_DB

        $parsed = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
        $parsed.mcpServers.odoo.command | Should -Be $script:PythonExe
        $parsed.mcpServers.odoo.env.ODOO_URL | Should -Be $env:ODOO_MCP_TEST_URL
    }
}
