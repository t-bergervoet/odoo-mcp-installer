# Odoo MCP Installer for Claude Desktop

**[⬇ Download the latest release](https://github.com/t-bergervoet/odoo-mcp-installer/releases/latest)** — grab the `.zip`, unzip it, double-click `Install-OdooMCP.bat`.

A one-click Windows installer for the [Odoo MCP server](https://github.com/pantalytics/odoo-mcp-pro), which lets Claude Desktop query and update your Odoo ERP data directly from chat (contacts, sales orders, inventory, invoices, etc.).

This tool exists because getting that server working by hand involves installing Python, installing Git, installing the package, and hand-editing a JSON config file correctly — all things that are easy to get subtly wrong. This installer does all of it for you, with a small GUI to enter your Odoo credentials and a built-in connection test before anything is written to disk.

No admin rights required. No pre-installed Python or Git required.

## What it does

1. Installs a private, self-contained copy of **Python 3.12** (the "embeddable" distribution) under `%LOCALAPPDATA%\Programs\PythonEmbed312`. It does not touch or conflict with any Python you already have installed.
2. Installs a portable copy of **Git** (MinGit) under `%LOCALAPPDATA%\Programs\MinGit`, but only if `git` isn't already on your `PATH`.
3. Installs the `mcp-server-odoo` package from [pantalytics/odoo-mcp-pro](https://github.com/pantalytics/odoo-mcp-pro) into that private Python.
4. Tests the connection to your Odoo instance with the credentials you enter, **before** writing anything.
5. Writes (or merges into) `%APPDATA%\Claude\claude_desktop_config.json` so Claude Desktop picks up the `odoo` MCP server on next launch — without touching any other MCP servers or settings already in that file.

## Requirements

- Windows 10 or 11
- [Claude Desktop](https://claude.ai/download) installed
- Internet access (to download Python, Git, and the MCP server package)
- An Odoo API key. In Odoo: **Settings → Users → (your user) → Account Security → API Keys → New API Key**
- Your Odoo login email (used together with the API key for authentication)

## Usage

1. Download this repository (or at minimum `Install-OdooMCP.ps1`, `Install-OdooMCP.bat`, and `OdooMcpInstaller.psm1`) onto the target machine, keeping all three files in the same folder — the `.ps1` imports the `.psm1` from its own folder.
2. Double-click **`Install-OdooMCP.bat`**.
   - If Windows shows a SmartScreen warning (because the script isn't code-signed), click **More info → Run anyway**.
3. Fill in the fields:
   | Field | Description |
   |---|---|
   | **Odoo URL** | e.g. `https://mycompany.odoo.com` |
   | **Odoo API Key** | From Odoo's Account Security settings |
   | **Username** | Your Odoo login email — required for most hosted/SaaS Odoo instances |
   | **Database** | Usually only needed for self-hosted, multi-database Odoo. Click **Auto-detect DB** first — it often fills this in for you. Leave blank if unsure and unneeded. |
4. Click **Test Connection**. Fix any reported error before continuing (see Troubleshooting below).
5. Click **Install**. This installs everything and re-verifies the connection before saving.
6. **Fully quit and reopen Claude Desktop** (quit from the system tray icon too, not just close the window) so it picks up the new server.
7. Start a new chat in Claude Desktop and check that Odoo-related tools are available (e.g. ask it to list a few contacts).

## Deploying to multiple machines

Just copy this folder to each machine and repeat the steps above — each machine gets its own private Python/Git install and its own credentials. There's nothing to install centrally or license per-seat.

## Testing

The installable logic lives in [`OdooMcpInstaller.psm1`](OdooMcpInstaller.psm1), kept separate from the GUI (`Install-OdooMCP.ps1`) specifically so it can be tested with [Pester](https://pester.dev/) independent of any UI. Tests live in [`tests/OdooMcpInstaller.Tests.ps1`](tests/OdooMcpInstaller.Tests.ps1).

**Unit tests** (no network access, run in a few seconds) cover config-file merging/recovery and output-parsing logic:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
Invoke-Pester -Path .\tests\OdooMcpInstaller.Tests.ps1 -Output Detailed
```

**Integration tests** exercise the real, full install path end-to-end: downloading a throwaway Python and Git into a temp directory, installing the actual package from GitHub, authenticating against a real Odoo instance, and writing a config file — this is what actually proves the "fresh Windows PC" scenario works, and it's also the regression test for the "Test Connection hangs forever" bug (asserts a successful auth resolves in well under the function's internal timeout). They're skipped automatically unless you provide credentials for a test Odoo instance:

```powershell
$env:ODOO_MCP_TEST_URL = "https://your-test-instance.odoo.com"
$env:ODOO_MCP_TEST_API_KEY = "..."
$env:ODOO_MCP_TEST_USER = "you@example.com"
$env:ODOO_MCP_TEST_DB = "your-test-db"          # optional
Invoke-Pester -Path .\tests\OdooMcpInstaller.Tests.ps1 -Output Detailed
```

CI ([`.github/workflows/test.yml`](.github/workflows/test.yml)) runs the unit tests on every push and pull request on a clean `windows-latest` runner. If you add `ODOO_MCP_TEST_URL`/`ODOO_MCP_TEST_API_KEY`/`ODOO_MCP_TEST_USER`/`ODOO_MCP_TEST_DB` as repository secrets (pointing at a disposable test Odoo instance), CI will also run the full integration suite automatically.

## Troubleshooting

**"Server disconnected" in Claude Desktop after install**
Fully quit Claude Desktop (including from the system tray — not just closing the window) and reopen it. Claude Desktop only loads MCP server config at startup.

**`Authentication failed` / `Username required with API key`**
Your Odoo instance doesn't have the vendor's native MCP module installed, so the server falls back to standard XML-RPC auth, which requires a username alongside the API key. Fill in the **Username** field with your Odoo login email.

**`database "..." does not exist`**
Auto-detection guessed the wrong database name. Click **Auto-detect DB** to query the real list from the server, or ask your Odoo administrator for the exact database name and enter it manually.

**Logs**
Claude Desktop writes MCP server logs to:
```
%LOCALAPPDATA%\Claude\logs\mcp-server-odoo.log
%LOCALAPPDATA%\Claude\logs\mcp.log
```
These show the exact startup/auth errors if something still isn't working after following the steps above.

**"Test Connection" or "Install" window freezes/hangs (fixed in v1.0.1)**
If you're on an older copy of this installer: when authentication actually succeeds, the Odoo MCP server process stays running (it waits on stdio for a client), so reading its output until the process closed would wait forever. v1.0.1+ reads output asynchronously and kills the process as soon as a conclusive result is seen, instead of waiting for it to exit. Update to the [latest release](https://github.com/t-bergervoet/odoo-mcp-installer/releases/latest) if you hit this.

**Re-running the installer**
Safe to run again — it detects the existing Python/Git/package install and skips reinstalling them, and it merges into the existing config rather than overwriting other MCP servers.

## Security notes

- Your Odoo API key is written in plain text inside `%APPDATA%\Claude\claude_desktop_config.json`, which is how Claude Desktop expects MCP server credentials to be provided. Treat that file with the same care as any other credential file.
- Don't commit real credentials to this repository, and don't bake credentials into the script before distributing it — always enter them through the GUI on each target machine.
- If a key is ever pasted somewhere it shouldn't be (chat, ticket, etc.), rotate it in Odoo's Account Security settings.

## License

The installer scripts in this repository (`Install-OdooMCP.ps1`, `Install-OdooMCP.bat`) are provided under the [MIT License](LICENSE).

This tool installs and configures the third-party [`odoo-mcp-pro`](https://github.com/pantalytics/odoo-mcp-pro) package, which is separately licensed (dual MPL-2.0 / Elastic License 2.0) by its authors. This repository does not redistribute or relicense that package — see its own repository for its license terms.
