$ErrorActionPreference = 'Stop'

[int]$attemptCount = 1
if ($env:SYSTEM_JOBATTEMPT) { $attemptCount = [int]$env:SYSTEM_JOBATTEMPT }
if ($attemptCount -gt 3) {
    Write-Host "##vso[task.logissue type=warning]Circuit Breaker: max attempts. Halting."
    exit 0
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    if ($null -ne [System.Net.WebRequest]::DefaultWebProxy) {
        [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    }

    # ── UNSUBSTITUTED-MACRO GUARD ─────────────────────────────────────────
    # BUGFIX (real incident): when a pipeline template's env: block references
    # a variable that does NOT exist in any linked variable group (e.g.
    # "AZURE_OPENAI_KEY: $(AZURE_OPENAI_KEY)" after that variable was removed
    # from the Library), ADO does NOT blank it out -- it leaves the literal
    # text "$(AZURE_OPENAI_KEY)" as the env var's actual string value. That
    # text is non-empty/non-whitespace, so a plain "if ($env:X)" truthy check
    # reads it as "the key IS set", selects Azure as the provider, and sends
    # the literal garbage string "$(AZURE_OPENAI_KEY)" to Azure as the actual
    # api-key header -- which Azure correctly rejects with 401, but only AFTER
    # silently picking the wrong provider and wasting the call. This helper
    # is the single place every credential/config env var is read through, so
    # an unsubstituted macro is detected and treated as NOT SET everywhere,
    # rather than depending on each call site to remember to check for it.
    function Get-CleanEnvValue {
        param([string]$RawValue)
        if ([string]::IsNullOrWhiteSpace($RawValue)) { return "" }
        $trimmed = ($RawValue -replace '[\r\n\s]+', '')
        # An ADO macro that never got substituted looks EXACTLY like
        # "$(SomeVariableName)" -- the whole trimmed string, start to end,
        # nothing else around it. A genuine secret/URL/deployment-name value
        # would never legitimately take this exact shape.
        if ($trimmed -match '^\$\([A-Za-z_][A-Za-z0-9_.]*\)$') { return "" }
        return $trimmed
    }

    # ── AI Provider configuration ──────────────────────────────────────
    # Supports Azure OpenAI (GPT-5) AND Gemini simultaneously.
    # Azure OpenAI takes priority when AZURE_OPENAI_KEY is set.
    # Fall back to Gemini when only GEMINI_API_KEY is set.
    # Both keys can exist — provider is selected at runtime automatically.
    # All reads now go through Get-CleanEnvValue (see guard above) so an
    # unsubstituted "$(VAR_NAME)" macro is never mistaken for a real value.
    [string]$aoaiKey        = if ($v = Get-CleanEnvValue $env:AZURE_OPENAI_KEY)        { $v } else { "" }
    [string]$aoaiDeployment = if ($v = Get-CleanEnvValue $env:AZURE_OPENAI_DEPLOYMENT) { $v } else { "gpt-5" }
    [string]$aoaiEndpoint   = if ($v = Get-CleanEnvValue $env:AZURE_OPENAI_ENDPOINT)   { $v } else { "https://devops-ai-openaikey.services.ai.azure.com" }
    [string]$geminiKey      = if ($v = Get-CleanEnvValue $env:GEMINI_API_KEY)          { $v } else { "" }
    [string]$geminiUri      = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
    [string]$webhookUrl     = if ($v = Get-CleanEnvValue $env:POWER_AUTOMATE_WEBHOOK)  { $v } else { "" }
    [string]$systemToken    = if ($v = Get-CleanEnvValue $env:SYSTEM_ACCESSTOKEN)      { $v } else { "" }
    [string]$repoProvider   = if ($env:BUILD_REPOSITORY_PROVIDER){ $env:BUILD_REPOSITORY_PROVIDER } else { "TfsGit" }

    # ── AZURE MODEL-FAMILY AUTO-DETECTION ────────────────────────────────
    # Different model families deployed on the SAME Foundry resource speak
    # genuinely different APIs -- CONFIRMED VIA RESEARCH (Microsoft's own
    # SDK-overview docs): the OpenAI SDK/Chat-Completions surface covers GPT,
    # Grok, DeepSeek, Llama, Mistral, and most of the catalog (Foundry
    # explicitly documents v1 chat completions as usable with "models from
    # other providers like DeepSeek and Grok which support the OpenAI v1
    # chat completions syntax"). Anthropic Claude models are the real
    # exception: confirmed via Microsoft's own docs and multiple independent
    # reports that Claude on Foundry ONLY responds to the Anthropic Messages
    # API (/anthropic/v1/messages, x-api-key header, different request/
    # response JSON shape) -- sending it an OpenAI-shaped request returns a
    # 404, not a translated response.
    #
    # Detection: the deployment NAME is the only signal available without an
    # extra discovery API call, and Claude deployment names always start
    # with "claude-" (claude-sonnet-4-6, claude-opus-4-7, claude-haiku-4-5,
    # etc. -- confirmed against the actual Foundry model catalog). This is a
    # genuine two-way split, not a per-vendor guess: anything NOT named
    # claude-* is assumed OpenAI-compatible, which covers every other family
    # Foundry documents as v1-chat-completions-compatible.
    #
    # AOAI_API_FAMILY lets a person override this explicitly (e.g. a future
    # model family that doesn't fit either shape) without needing a code
    # change -- if set to "anthropic" or "openai" it wins outright; auto-
    # detection only runs when the variable is absent.
    [string]$aoaiApiFamilyOverride = (Get-CleanEnvValue $env:AOAI_API_FAMILY).ToLower()
    [bool]$aoaiIsClaude = if ($aoaiApiFamilyOverride -eq 'anthropic') { $true }
                          elseif ($aoaiApiFamilyOverride -eq 'openai') { $false }
                          else { $aoaiDeployment -match '(?i)^claude[-_]' }

    # ── REASONING-MODEL TOKEN-PARAMETER DETECTION ─────────────────────────
    # CONFIRMED VIA RESEARCH (multiple independent reports, including a real
    # Azure SDK bug thread): GPT-5-family and o-series ("reasoning") models
    # reject the older "max_tokens" parameter outright with a 400 ("Unsupported
    # parameter: 'max_tokens' is not supported with this model. Use
    # 'max_completion_tokens' instead") -- this is NOT a deprecation warning,
    # it's a hard request failure. Conversely, some legacy models (confirmed:
    # GPT-4 turbo-2024-04-09) reject "max_completion_tokens" and REQUIRE the
    # old "max_tokens" name -- so this cannot be a global swap; it has to be
    # model-aware, exactly like the Claude detection above.
    # Detection covers gpt-5 (incl. gpt-5.x and gpt-5-* variants like
    # gpt-5-mini/gpt-5-nano/gpt-5-chat) and the o-series reasoning models
    # (o1, o3, o4-mini, etc.) -- both confirmed via research to require
    # max_completion_tokens. Plain gpt-4/gpt-4o/gpt-4.1/gpt-3.5 and non-OpenAI
    # catalog models (Grok, DeepSeek) keep the original max_tokens, which is
    # both their confirmed requirement and the existing, already-working
    # default for every model tested against this engine so far.
    [bool]$aoaiUsesMaxCompletionTokens = ($aoaiDeployment -match '(?i)^gpt-5|^o[0-9]')

    # Determine active AI provider — Azure OpenAI wins if both keys present
    [string]$aiProvider = if (-not [string]::IsNullOrWhiteSpace($aoaiKey)) { "AzureOpenAI" } `
                          elseif (-not [string]::IsNullOrWhiteSpace($geminiKey)) { "Gemini" } `
                          else { "" }

    if ([string]::IsNullOrWhiteSpace($aiProvider)) {
        throw "CRITICAL: Set AZURE_OPENAI_KEY (Azure OpenAI / GPT-5) or GEMINI_API_KEY (Gemini) — at least one AI provider key is required."
    }
    if ([string]::IsNullOrWhiteSpace($webhookUrl) -or [string]::IsNullOrWhiteSpace($systemToken)) {
        throw "CRITICAL: POWER_AUTOMATE_WEBHOOK and System.AccessToken are required."
    }
    Write-Host "[INFO] AI Provider: $aiProvider $(if ($aiProvider -eq 'AzureOpenAI') { "→ $aoaiDeployment ($(if ($aoaiIsClaude) { 'Anthropic Messages API' } else { 'OpenAI Chat Completions API' })) @ $aoaiEndpoint" } else { "→ gemini-2.5-flash" })"


    [string]$buildId           = $env:BUILD_BUILDID
    [string]$definitionId      = $env:SYSTEM_DEFINITIONID
    [string]$collectionUri     = $env:SYSTEM_COLLECTIONURI
    [string]$teamProject       = $env:SYSTEM_TEAMPROJECT
    [string]$repoId            = $env:BUILD_REPOSITORY_ID
    $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$systemToken"))

    [string]$sourceVersion = if (-not [string]::IsNullOrWhiteSpace($env:SYSTEM_PULLREQUEST_SOURCECOMMITID)) {
        $env:SYSTEM_PULLREQUEST_SOURCECOMMITID } else { $env:BUILD_SOURCEVERSION }
    $safeRealBranch = if (-not [string]::IsNullOrWhiteSpace($env:SYSTEM_PULLREQUEST_SOURCEBRANCH)) {
        $env:SYSTEM_PULLREQUEST_SOURCEBRANCH } else { $env:BUILD_SOURCEBRANCH }
    [string]$cleanFailedBranch = if (-not [string]::IsNullOrWhiteSpace($safeRealBranch)) {
        $safeRealBranch -replace '^refs/(heads|pull|tags)/', '' } else { "unknown-branch" }

    Write-Host "[INFO] Commit: $sourceVersion  Branch: $cleanFailedBranch"

    function Invoke-ADORestMethod {
        param([string]$Uri)
        $delay = 2
        for ($i = 0; $i -lt 3; $i++) {
            try { return Invoke-RestMethod -Uri $Uri -Headers @{ Authorization = "Basic $auth" } -ErrorAction Stop }
            catch {
                # BUGFIX: a connection-refused, DNS failure, or other network-
                # level error (confirmed real-world case: "No connection
                # could be made because the target machine actively refused
                # it") never produces an HTTP response object at all --
                # .Exception.Response is genuinely $null in that case, not
                # just absent of a StatusCode. Checking .StatusCode directly
                # on a null .Response throws its own PropertyNotFoundException
                # under this script's global $ErrorActionPreference='Stop' --
                # a SECOND, unrelated crash happening INSIDE the catch block
                # meant to handle the FIRST failure, which would skip the
                # retry/backoff loop entirely and propagate as an unhandled
                # error instead of the graceful $null return this function
                # is designed to give callers.
                if ($null -ne $_.Exception.Response -and $_.Exception.Response.StatusCode -eq 'NotFound') { return $null }
                if ($null -ne $_.Exception.Response -and ($_.Exception.Response.StatusCode -eq 'TooManyRequests' -or $_.Exception.Message -match '503|timeout|connection')) { Start-Sleep -Seconds $delay; $delay *= 2 }
                elseif ($null -eq $_.Exception.Response -and $_.Exception.Message -match '503|timeout|connection|refused|could not be resolved') { Start-Sleep -Seconds $delay; $delay *= 2 }
                else { return $null }
            }
        }
        return $null
    }

    $artifactDir = Join-Path $env:AGENT_TEMPDIRECTORY "AIPayload"
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
    $workRoot = Join-Path $env:AGENT_TEMPDIRECTORY "RepairWork"
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

    # ── Ensure shellcheck is available (OS-aware: brew on macOS, apt on Linux) ─
    # shellcheck is a STATIC analyzer: catches unbound vars, bad quoting, useless-grep
    # WITHOUT executing the script (unsafe in a pipeline). bash -n stays the floor.
    # Try to install PSScriptAnalyzer for PowerShell semantic analysis.
    # Install-Module is safe to call even if already installed (Force+SkipPublisherCheck).
    $oldEApsa = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    if ($null -eq (Get-Command Invoke-ScriptAnalyzer -EA SilentlyContinue)) {
        try {
            $j = Start-Job { Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop 2>$null }
            Wait-Job $j -Timeout 90 | Out-Null; Remove-Job $j -Force -EA SilentlyContinue
            if ($null -ne (Get-Command Invoke-ScriptAnalyzer -EA SilentlyContinue)) { Write-Host "[INFO] PSScriptAnalyzer installed." }
        } catch { Write-Host "[WARN] PSScriptAnalyzer install failed — PS semantic checks disabled." }
    }
    $ErrorActionPreference = $oldEApsa

    $script:hasShellcheck = $false
    $oldEAsc = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    if ($null -ne (Get-Command shellcheck -ErrorAction SilentlyContinue)) {
        $script:hasShellcheck = $true
        $scVersion = (& shellcheck --version 2>$null | Select-String 'version:').ToString().Trim()
        Write-Host "[INFO] ✅ shellcheck FOUND and ACTIVE — $scVersion"
    } else {
        Write-Host "[INFO] shellcheck not found; attempting OS-appropriate install..."
        # NOTE: do NOT name these $isWindows / $isMacOS — those collide with the
        # read-only automatic variables $IsWindows / $IsMacOS in PowerShell Core
        # (variable names are case-insensitive) and throw "Cannot overwrite variable".
        # Check Windows FIRST (no uname dependency) so a missing uname on Windows
        # can't leave $onWindows unset and wrongly fall through to apt-get.
        $onWindows = ($IsWindows -or $env:OS -eq 'Windows_NT' -or $null -ne $env:WINDIR)
        $onMac     = $false
        if (-not $onWindows) {
            try { $onMac = ($IsMacOS -or (uname 2>$null) -eq 'Darwin') } catch { $onMac = $false }
        }
        if ($onMac) {
            if ($null -ne (Get-Command brew -ErrorAction SilentlyContinue)) { $j = Start-Job { brew install shellcheck 2>$null }; Wait-Job $j -Timeout 120 | Out-Null; Remove-Job $j -Force -ErrorAction SilentlyContinue }
        } elseif ($onWindows) {
            Write-Host "[INFO] Windows agent — shellcheck not auto-installed. bash -n remains the syntax floor."
            if ($null -ne (Get-Command choco -EA SilentlyContinue)) { $j = Start-Job { choco install shellcheck -y 2>$null }; Wait-Job $j -Timeout 120 | Out-Null; Remove-Job $j -Force -EA SilentlyContinue }
        } else {
            $j = Start-Job { sudo apt-get update -qq 2>$null; sudo apt-get install -y -qq shellcheck 2>$null }; Wait-Job $j -Timeout 120 | Out-Null; Remove-Job $j -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne (Get-Command shellcheck -ErrorAction SilentlyContinue)) { $script:hasShellcheck = $true; Write-Host "[INFO] shellcheck installed." }
        else { Write-Host "[WARN] shellcheck unavailable; deep static checks disabled, bash -n still active." }
    }
    $ErrorActionPreference = $oldEAsc

    # ── TOOL-AVAILABILITY CACHE — compute once, reuse for the rest of the run ──
    # Get-SyntaxError runs once per AI-fix loop ITERATION (up to $MAX_ITERS_PER_FILE,
    # i.e. up to 25x for a single stubborn file), and every Get-Command lookup for an
    # external tool inside it was being re-run on every single iteration -- pure
    # waste, since none of these tools self-install mid-run the way shellcheck does
    # above (confirmed: no npm/pip/gem/brew install for any of these appears anywhere
    # else in this script). Computed once here, before the per-file loop starts,
    # following the exact same pattern already proven correct for $script:hasShellcheck.
    $oldEAtools = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $script:hasTsc        = $null -ne (Get-Command tsc        -EA SilentlyContinue)
    $script:hasEslint     = $null -ne (Get-Command eslint     -EA SilentlyContinue)
    $script:hasPyflakes   = $null -ne (Get-Command pyflakes   -EA SilentlyContinue)
    $script:hasSwiftc     = $null -ne (Get-Command swiftc     -EA SilentlyContinue)
    $script:hasSwiftlint  = $null -ne (Get-Command swiftlint  -EA SilentlyContinue)
    $script:hasJavac      = $null -ne (Get-Command javac      -EA SilentlyContinue)
    $script:hasDotnet     = $null -ne (Get-Command dotnet     -EA SilentlyContinue)
    $script:hasGofmt      = $null -ne (Get-Command gofmt      -EA SilentlyContinue)
    $script:hasGo         = $null -ne (Get-Command go         -EA SilentlyContinue)
    $script:hasKotlinc    = $null -ne (Get-Command kotlinc    -EA SilentlyContinue)
    $script:hasPhp        = $null -ne (Get-Command php        -EA SilentlyContinue)
    $script:hasPhpstan    = $null -ne (Get-Command phpstan    -EA SilentlyContinue)
    $script:hasRubocop    = $null -ne (Get-Command rubocop    -EA SilentlyContinue)
    $script:hasTerraform  = $null -ne (Get-Command terraform  -EA SilentlyContinue)
    $script:hasHadolint   = $null -ne (Get-Command hadolint   -EA SilentlyContinue)
    $script:hasVueTsc     = $null -ne (Get-Command 'vue-tsc'  -EA SilentlyContinue)
    # BUGFIX (real incident, confirmed via live test run): node --check was
    # called UNCONDITIONALLY at two call sites (.ts and .js fallback paths)
    # with no Get-Command guard, unlike every other external tool in this
    # script. On an agent without Node.js on PATH, this throws a terminating
    # CommandNotFoundException which -- because $ErrorActionPreference is
    # 'Stop' at the top of this script -- becomes a CRITICAL EXCEPTION that
    # kills the ENTIRE run, not just the one file being checked. A real test
    # run reproduced this exactly: deployment.yaml and Dockerfile were fixed
    # correctly, then the very next .js candidate file crashed the whole
    # engine before the Teams payload was ever built with real content.
    # ── PORTABLE TOOL AUTO-INSTALL (no admin rights required) ─────────────
    # NEW CAPABILITY: previously, a missing Node.js/Python3 just meant the
    # structural fallback ran instead -- real coverage, but weaker than the
    # actual interpreter (e.g. Python's fallback genuinely cannot catch
    # indentation errors, the single most common real Python mistake).
    # This installs the missing tool directly from its official distributor
    # (nodejs.org / python.org) as a portable zip extraction -- the same
    # admin-free technique already confirmed correct for getting tools onto
    # a locked-down self-hosted agent (no installer execution, no registry
    # writes, no elevation prompt -- just download + unzip + PATH).
    #
    # PERSISTENT BY DESIGN: installs to a FIXED folder under the user's own
    # profile ($env:USERPROFILE\.triage-tools\<tool>), NOT the build
    # workspace or temp directory -- both of those get wiped/recreated by
    # ADO between runs, which would force a fresh ~30MB+ download on EVERY
    # single pipeline execution. Installing under the user profile means
    # the cost is paid exactly once per agent, ever (until manually removed).
    #
    # SAFETY: idempotent (checks for the expected binary before downloading
    # anything -- a second run is a no-op), never requires admin, has a
    # hard 180s download timeout, and is wrapped so ANY failure (no network,
    # blocked egress, corrupt zip, whatever) falls through silently to the
    # existing structural-check fallback rather than affecting the rest of
    # the run. Genuinely best-effort: this is an enhancement on top of an
    # already-working fallback path, never a replacement for it.

    # ── PIP + PYFLAKES BOOTSTRAP (extracted, reusable) ────────────────────
    # NEW: the embeddable Python distro ships with neither pip nor any
    # third-party packages. Without this, every .py file's semantic check
    # (pyflakes) was either skipped or -- before an earlier bugfix --
    # silently reported a confusing "ModuleNotFoundError: No module named
    # 'pyflakes'" as if it were a bug IN the file being checked. Confirmed
    # process via research (multiple independent sources, same steps):
    # download get-pip.py, run it with python.exe (only works once "import
    # site" is enabled in the ._pth file), then pip install the package
    # needed. Extracted into its own function (rather than left inline in
    # the fresh-install path) because it needs to be callable from TWO
    # places: right after a brand-new Python install, AND on every
    # SUBSEQUENT run if a prior run's bootstrap never completed -- the
    # idempotency check below only verifies python.exe itself exists,
    # which says nothing about whether pip/pyflakes were ever successfully
    # added on top of it. Wrapped in its own try/catch so a failure here
    # degrades to syntax-only checking rather than affecting anything else.
    function Install-PipAndPyflakes {
        param([string]$PythonExePath, [string]$ToolRoot)
        try {
            $getPipPath = Join-Path $ToolRoot 'get-pip.py'
            Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $getPipPath -TimeoutSec 60 -EA Stop

            # BUGFIX: native external-process calls (the & call operator)
            # have NO PowerShell-level timeout of their own, unlike every
            # Invoke-WebRequest/Invoke-RestMethod call elsewhere in this
            # script, which all carry an explicit -TimeoutSec. A network
            # stall during pip's own bootstrap or package download (DNS
            # hang, slow PyPI response, partial connectivity) could block
            # this call -- and therefore the ENTIRE engine run -- 
            # indefinitely with no recovery. Wrapped in the same
            # Start-Job/Wait-Job -Timeout pattern already established and
            # proven elsewhere in this script (see the shellcheck choco
            # install above) rather than inventing a new mechanism.
            $pipJob = Start-Job -ScriptBlock {
                param($py, $script)
                & $py $script --no-warn-script-location 2>&1
            } -ArgumentList $PythonExePath, $getPipPath
            $pipJobDone = Wait-Job $pipJob -Timeout 90
            $pipOut = if ($null -ne $pipJobDone) { Receive-Job $pipJob } else { "pip bootstrap timed out after 90s" }
            Remove-Job $pipJob -Force -EA SilentlyContinue
            Remove-Item -Path $getPipPath -Force -EA SilentlyContinue

            $pipCheck = & $PythonExePath -m pip --version 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[ToolInstall] ✅ pip bootstrapped for embeddable Python."
                $pyflakesJob = Start-Job -ScriptBlock {
                    param($py)
                    & $py -m pip install pyflakes --no-warn-script-location --quiet 2>&1
                } -ArgumentList $PythonExePath
                $pyflakesJobDone = Wait-Job $pyflakesJob -Timeout 90
                $pyflakesOut = if ($null -ne $pyflakesJobDone) { Receive-Job $pyflakesJob } else { "pyflakes install timed out after 90s" }
                Remove-Job $pyflakesJob -Force -EA SilentlyContinue
                # Re-check directly (the job's own exit code isn't reliably
                # forwarded through Receive-Job) -- a real, fast, local
                # check rather than trusting job plumbing for the verdict.
                $pyflakesVerify = & $PythonExePath -c "import pyflakes" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "[ToolInstall] ✅ pyflakes installed — Python files now get real semantic checking, not just syntax."
                } else {
                    Write-Host "[ToolInstall] ⚠️ pyflakes install failed or timed out: $pyflakesOut. Python files get syntax-only checking (py_compile) for this run."
                }
            } else {
                Write-Host "[ToolInstall] ⚠️ pip bootstrap did not produce a working pip ($pipOut). Python files get syntax-only checking (py_compile) for this run."
            }
        } catch {
            Write-Host "[ToolInstall] ⚠️ pip/pyflakes bootstrap failed: $($_.Exception.Message). Python files get syntax-only checking (py_compile) for this run -- the already-working Python install is unaffected."
        }
    }

    function Install-PortableToolIfMissing {
        param(
            [ValidateSet('node','python')][string]$Tool
        )
        $toolRoot = Join-Path $env:USERPROFILE ".triage-tools\$Tool"
        $exePath  = if ($Tool -eq 'node') { Join-Path $toolRoot 'node.exe' } else { Join-Path $toolRoot 'python.exe' }

        # Idempotency check FIRST -- if a prior run already installed this
        # successfully, skip straight to PATH update with zero network
        # activity. This is what makes the "persist permanently" design
        # actually pay off: every run after the first is instant here.
        if (Test-Path $exePath) {
            Write-Host "[ToolInstall] $Tool already installed at $toolRoot — adding to PATH for this run."
            $env:PATH = "$toolRoot;$env:PATH"
            # BUGFIX: this check previously only verified python.exe itself
            # exists before returning early -- it never checked whether
            # pip/pyflakes were ALSO successfully bootstrapped in a prior
            # run. A prior run could install Python successfully but have
            # the separate pip/pyflakes bootstrap fail (or simply not have
            # existed yet, before that feature was added) -- every run
            # after that would silently stay on syntax-only checking
            # forever, with no further attempt to close the gap. For
            # python specifically, re-probe pyflakes here and retry JUST
            # the pip/pyflakes bootstrap (not the whole ~10MB zip download)
            # if it's still missing -- cheap, and pip install is itself
            # idempotent (a no-op if already satisfied).
            if ($Tool -eq 'python') {
                $pyflakesCheck = & $exePath -c "import pyflakes" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "[ToolInstall] pyflakes not yet present for this Python install — attempting bootstrap (one-time, persists like the Python install itself)..."
                    Install-PipAndPyflakes -PythonExePath $exePath -ToolRoot $toolRoot
                }
            }
            return $true
        }

        Write-Host "[ToolInstall] $Tool not found on PATH and not yet installed at $toolRoot — attempting portable install..."
        try {
            New-Item -ItemType Directory -Path $toolRoot -Force -EA Stop | Out-Null
            $zipPath = Join-Path $env:TEMP "triage-install-$Tool-$([guid]::NewGuid().ToString('N')).zip"

            if ($Tool -eq 'node') {
                # CONFIRMED VIA RESEARCH: nodejs.org/download/release/latest-v22.x/
                # is a real, currently-maintained index page that always reflects
                # the CURRENT latest 22.x LTS patch release -- fetching it and
                # extracting the real version number avoids ever hardcoding a
                # version that goes stale. 22.x chosen as the currently-active
                # LTS line (confirmed real, current release present in research
                # at the time this was written) rather than the newest major,
                # for the same stability-over-bleeding-edge reasoning already
                # used elsewhere in this script (e.g. lock-file-pinned dependency
                # versions over "always fetch latest").
                $indexHtml = Invoke-RestMethod -Uri 'https://nodejs.org/download/release/latest-v22.x/' -TimeoutSec 30 -EA Stop
                $verMatch = [regex]::Match("$indexHtml", 'node-v(22\.\d+\.\d+)-win-x64\.zip')
                if (-not $verMatch.Success) { throw "Could not determine current Node.js 22.x version from release index." }
                $nodeVer = $verMatch.Groups[1].Value
                $downloadUrl = "https://nodejs.org/download/release/v$nodeVer/node-v$nodeVer-win-x64.zip"
                Write-Host "[ToolInstall] Downloading Node.js v$nodeVer from $downloadUrl ..."
                Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -TimeoutSec 180 -EA Stop
                $extractTemp = Join-Path $env:TEMP "triage-extract-node-$([guid]::NewGuid().ToString('N'))"
                Expand-Archive -Path $zipPath -DestinationPath $extractTemp -Force -EA Stop
                # The zip contains one top-level folder (node-v22.x.x-win-x64\) --
                # move its CONTENTS up so node.exe lands directly at $toolRoot,
                # matching the flat layout $exePath expects.
                $innerFolder = Get-ChildItem -Path $extractTemp -Directory | Select-Object -First 1
                if ($null -eq $innerFolder) { throw "Extracted Node.js zip did not contain the expected folder structure." }
                Get-ChildItem -Path $innerFolder.FullName | Move-Item -Destination $toolRoot -Force -EA Stop
                Remove-Item -Path $extractTemp -Recurse -Force -EA SilentlyContinue
            } else {
                # PYTHON: confirmed via research that python.org has no clean
                # "latest" redirect the way Node does -- versions are spread
                # across multiple actively-maintained branches (3.13.x, 3.14.x
                # both current). Resolve the current highest 3.13.x patch
                # DYNAMICALLY from python.org's own directory index, the same
                # live-discovery pattern already used for Node.js above,
                # rather than a string that goes stale. 3.13.x specifically
                # (not "whatever is newest overall") because it's a long-
                # established, widely-compatible line -- jumping to the
                # newest major the moment it appears risks a brand-new
                # release with rougher edges, the same stability-over-
                # bleeding-edge reasoning already applied to dependency-
                # version fixes elsewhere in this script. A hardcoded
                # fallback version is kept ONLY as a last resort if the
                # dynamic lookup itself fails (no network, page format
                # changed, etc.) -- so a transient lookup failure degrades
                # gracefully to a known-good version rather than crashing
                # the whole install.
                $pyVer = $null
                try {
                    $ftpIndexHtml = Invoke-RestMethod -Uri 'https://www.python.org/ftp/python/' -TimeoutSec 30 -EA Stop
                    $pyVerMatches = [regex]::Matches("$ftpIndexHtml", '3\.13\.(\d+)/')
                    if ($pyVerMatches.Count -gt 0) {
                        $highestPatch = ($pyVerMatches | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Descending | Select-Object -First 1)
                        $pyVer = "3.13.$highestPatch"
                        Write-Host "[ToolInstall] Resolved current Python 3.13.x version dynamically: $pyVer"
                    }
                } catch {
                    Write-Host "[ToolInstall] Could not dynamically resolve current Python version ($($_.Exception.Message)) — using last-known-good fallback."
                }
                if ([string]::IsNullOrWhiteSpace($pyVer)) { $pyVer = '3.13.13' }
                $downloadUrl = "https://www.python.org/ftp/python/$pyVer/python-$pyVer-embed-amd64.zip"
                Write-Host "[ToolInstall] Downloading Python $pyVer (embeddable) from $downloadUrl ..."
                Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -TimeoutSec 180 -EA Stop
                Expand-Archive -Path $zipPath -DestinationPath $toolRoot -Force -EA Stop

                # CONFIRMED VIA RESEARCH: the embeddable distro ships with a
                # restrictive ._pth file where the relevant line is shipped
                # COMMENTED OUT by default -- "# Uncomment to run site.main()
                # automatically" followed by "#import site" -- not simply
                # absent. This blocks "import site" and therefore blocks
                # py_compile/pyflakes from working at all out of the box.
                # Uncommenting the EXISTING line (rather than appending a new
                # one) is the documented fix and avoids any chance of the
                # directive running twice if duplicate active lines aren't
                # deduplicated by Python's .pth processing.
                $pthFile = Get-ChildItem -Path $toolRoot -Filter '*._pth' | Select-Object -First 1
                if ($null -ne $pthFile) {
                    $pthContent = Get-Content $pthFile.FullName -Raw
                    if ($pthContent -match '(?m)^\s*#\s*import site\s*$') {
                        $pthContent = $pthContent -replace '(?m)^\s*#\s*import site\s*$', 'import site'
                        Set-Content -Path $pthFile.FullName -Value $pthContent -NoNewline
                    } elseif ($pthContent -notmatch '(?m)^import site\s*$') {
                        # Defensive fallback in case a future Python version
                        # ships this file without the commented line at all --
                        # appending still correctly enables site importing.
                        Add-Content -Path $pthFile.FullName -Value "`nimport site"
                    }
                }
                # python.exe in the embeddable distro doesn't ship a "python3"
                # alias, but every call site in this script invokes "python3"
                # specifically -- create one so those calls resolve correctly
                # without needing to touch any existing call site.
                $python3Path = Join-Path $toolRoot 'python3.exe'
                if (-not (Test-Path $python3Path)) {
                    Copy-Item -Path (Join-Path $toolRoot 'python.exe') -Destination $python3Path -Force -EA Stop
                }

                # Bootstrap pip + pyflakes right after a fresh Python install --
                # see Install-PipAndPyflakes above for the full reasoning and
                # the confirmed process (this is also called from the
                # idempotency path below on subsequent runs, in case a prior
                # run's bootstrap never completed).
                Install-PipAndPyflakes -PythonExePath $exePath -ToolRoot $toolRoot
            }

            Remove-Item -Path $zipPath -Force -EA SilentlyContinue

            if (-not (Test-Path $exePath)) { throw "Expected binary not found at $exePath after extraction." }
            $env:PATH = "$toolRoot;$env:PATH"
            Write-Host "[ToolInstall] ✅ $Tool installed successfully at $toolRoot (persists for future runs)."
            return $true
        } catch {
            Write-Host "[ToolInstall] ⚠️ $Tool auto-install failed: $($_.Exception.Message). Falling back to structural checking for this tool, exactly as before this feature existed."
            return $false
        }
    }

    # ── REAL-TOOL VERIFICATION (not just Get-Command) ──────────────────────
    # BUGFIX (real incident, confirmed via live test run): Get-Command alone
    # is NOT a reliable presence check on Windows. Windows ships 0-byte "App
    # Execution Alias" stub files for python.exe/python3.exe/bash.exe (and
    # possibly others) in %LOCALAPPDATA%\Microsoft\WindowsApps, which is on
    # PATH BY DEFAULT on a clean Windows install -- CONFIRMED VIA RESEARCH
    # (Microsoft's own support forum: "Windows 10 and 11 have those two
    # listed in the App Execution Alias section... by default"). Get-Command
    # finds these stub FILES (they genuinely exist) and reports the tool as
    # present -- but running the stub does NOT execute the real tool at all;
    # it always prints a Microsoft Store install-redirect message and exits,
    # REGARDLESS of what arguments are passed (confirmed directly from this
    # engine's own real test log: "python3 -m py_compile app.py" -- a real
    # argument, not a bare invocation -- still printed "Python was not
    # found; run without arguments to install from the Microsoft Store").
    # This caused hasPython3 (and very likely hasBash) to be TRUE on the
    # real agent this engine runs on, even though neither tool actually
    # works -- which meant: (1) the auto-install logic above never even
    # tried to install Python, because its OWN Get-Command-based guard saw
    # the same false-positive stub and concluded nothing needed installing;
    # (2) every .py file fell through to the structural-only fallback
    # silently, with the engine believing it had real py_compile coverage.
    #
    # Fix: verify the tool by actually RUNNING it with a harmless flag and
    # checking the output looks like a real version string -- a stub prints
    # the Store-redirect message instead, which this regex will never match.
    function Test-RealToolPresent {
        param([string]$Command, [string[]]$VersionArgs)
        if ($null -eq (Get-Command $Command -EA SilentlyContinue)) { return $false }
        try {
            $out = & $Command @VersionArgs 2>&1 | Out-String
            # A genuine version string always contains at least one digit;
            # the Store-redirect stub message contains no version-like
            # digit sequence at all -- this is a deliberately simple,
            # robust check rather than trying to match the stub's exact
            # (and potentially locale-dependent) wording.
            if ("$out" -match '\d') { return $true }
            return $false
        } catch {
            return $false
        }
    }

    if (-not (Test-RealToolPresent -Command 'node' -VersionArgs @('--version'))) { [void](Install-PortableToolIfMissing -Tool 'node') }
    if (-not (Test-RealToolPresent -Command 'python3' -VersionArgs @('--version'))) { [void](Install-PortableToolIfMissing -Tool 'python') }

    $script:hasNode       = Test-RealToolPresent -Command 'node' -VersionArgs @('--version')
    # BUGFIX (real incident, confirmed via live test run): bash, python3, and
    # ruby were called UNCONDITIONALLY at their respective call sites with
    # ZERO detection anywhere in this script -- unlike every other external
    # tool, which all go through a Get-Command check first. The SAME live
    # test that caught the node crash also independently reproduced this for
    # bash: "##[error]Unable to locate executable file: 'bash'." on the very
    # real Windows agent this engine runs on. python3 and ruby have the
    # identical unguarded-call shape and would crash the same way the moment
    # a .py or .rb/Fastfile/Gemfile/Podfile candidate file is processed on
    # an agent without those tools on PATH.
    #
    # bash is deliberately NOT auto-installed (unlike node/python above) --
    # the realistic portable option (Git for Windows' bundled bash.exe) is a
    # much larger download with documented standalone quirks outside a full
    # Git install, while its existing structural fallback already catches
    # the most common real-world bash breakage (unclosed quotes/
    # substitutions -- the exact class Repair-AllUnclosedDelimiters targets).
    # A deliberate scope decision, not an oversight.
    #
    # All four now use Test-RealToolPresent (see above) instead of a bare
    # Get-Command check, for the same App-Execution-Alias-stub reason.
    $script:hasBash       = Test-RealToolPresent -Command 'bash' -VersionArgs @('--version')
    $script:hasPython3    = Test-RealToolPresent -Command 'python3' -VersionArgs @('--version')
    $script:hasRuby       = Test-RealToolPresent -Command 'ruby' -VersionArgs @('--version')
    $ErrorActionPreference = $oldEAtools
    Write-Host "[INFO] Tool cache: tsc=$($script:hasTsc) eslint=$($script:hasEslint) pyflakes=$($script:hasPyflakes) swiftc=$($script:hasSwiftc) swiftlint=$($script:hasSwiftlint) javac=$($script:hasJavac) dotnet=$($script:hasDotnet) gofmt=$($script:hasGofmt) go=$($script:hasGo) kotlinc=$($script:hasKotlinc) php=$($script:hasPhp) phpstan=$($script:hasPhpstan) rubocop=$($script:hasRubocop) terraform=$($script:hasTerraform) hadolint=$($script:hasHadolint) vue-tsc=$($script:hasVueTsc) node=$($script:hasNode) bash=$($script:hasBash) python3=$($script:hasPython3) ruby=$($script:hasRuby)"

    # ──────────────────────────────────────────────────────────────────
    #  INLINE-BASH EXTRACTION FROM YAML  (returns blocks + start line)
    # ──────────────────────────────────────────────────────────────────
    function Get-InlineScriptBlocks {
        param([string]$yamlContent)
        $lines  = $yamlContent -split "\r?\n"
        $blocks = @()
        $i = 0
        while ($i -lt $lines.Count) {
            $isScript     = ($lines[$i] -match '^(\s*)script:\s*\|')
            $isPwshScript = ($lines[$i] -match '^(\s*)(pwsh|powershell):\s*\|')
            if ($isScript -or $isPwshScript) {
                $startIdx = $i + 1
                # Look back up to 8 lines to find the task type / shell hint for THIS step.
                $lookbackStart = [Math]::Max(0, $i - 8)
                $preamble = ($lines[$lookbackStart..$i] -join "`n")
                $isPowerShell = $isPwshScript -or ($preamble -match '(?i)(PowerShell@\d|task:\s*PowerShell|pwsh:\s*true)')

                $body = [System.Collections.Generic.List[string]]::new()
                $contentIndent = -1
                $j = $startIdx
                while ($j -lt $lines.Count) {
                    $line = $lines[$j]
                    if ($line.Trim() -eq '') { $body.Add(''); $j++; continue }
                    $curIndent = ($line.Length - $line.TrimStart().Length)
                    if ($contentIndent -lt 0) { $contentIndent = $curIndent }
                    if ($curIndent -lt $contentIndent) { break }
                    $body.Add($(if ($line.Length -ge $contentIndent) { $line.Substring($contentIndent) } else { $line }))
                    $j++
                }
                $bodyText = ($body -join "`n")

                # Body-level confirmation: PowerShell markers vs bash shebang.
                if ($bodyText -match '(?im)(^\s*\$\w+\s*=|\bGet-Content\b|\bSet-Content\b|\$Env:|-replace\b|\bWrite-Host\b|\bInvoke-RestMethod\b|\bParam\s*\()') { $isPowerShell = $true }
                if ($bodyText -match '(?m)^\s*#!/usr/bin/env bash|^\s*#!/bin/(ba)?sh') { $isPowerShell = $false }

                # ── OS-TARGET DETECTION for bare 'script:' steps (not pwsh/powershell) ──
                # A bare 'script:' step runs Bash on Linux/macOS but cmd.exe (batch
                # syntax) on Windows agents (confirmed via Microsoft's docs). pool:/
                # vmImage: can be declared ONCE at the top of a pipeline (applying to
                # every job below) or overridden per-job/per-stage closer to this
                # specific step — so unlike the 8-line PowerShell-detection lookback
                # above, this scans the ENTIRE prefix from the start of the file to
                # this point and takes the LAST (closest) match, matching YAML's own
                # job-overrides-pipeline scoping precedence. Defaults to bash when no
                # Windows signal is found anywhere above — this pipeline's actual
                # observed stack is iOS/Fastlane (macOS) and Android/Gradle (Linux),
                # so an unindicated default should lean toward the common case rather
                # than guess Windows with no textual basis.
                $kindOverride = $null
                if (-not $isPowerShell) {
                    $fullPrefix = ($lines[0..$i] -join "`n")
                    $vmImageMatches = [regex]::Matches($fullPrefix, '(?im)vmImage:\s*[''"]?([a-zA-Z0-9_.\-]+)[''"]?')
                    $demandMatches  = [regex]::Matches($fullPrefix, '(?im)Agent\.OS\s*-equals\s*(\w+)')
                    $isWindowsTarget = $false
                    if ($vmImageMatches.Count -gt 0) {
                        $isWindowsTarget = $vmImageMatches[$vmImageMatches.Count - 1].Groups[1].Value -match '(?i)windows'
                    } elseif ($demandMatches.Count -gt 0) {
                        $isWindowsTarget = $demandMatches[$demandMatches.Count - 1].Groups[1].Value -eq 'Windows_NT'
                    }
                    if ($isWindowsTarget) { $kindOverride = 'cmd' }
                }

                $kind = if ($isPowerShell) { 'powershell' } elseif ($null -ne $kindOverride) { $kindOverride } else { 'bash' }
                $blocks += [PSCustomObject]@{ YamlStartLine = $startIdx + 1; ContentIndent = $contentIndent; Body = $bodyText; Kind = $kind }
                $i = $j
            } else { $i++ }
        }
        return $blocks
    }

    # PowerShell syntax oracle via the built-in Parser API (no install needed, deterministic).
    # Returns @{ Ok; Message; Line } where Line is the 1-based line WITHIN the script text.
    function Test-PowerShellSyntax {
        param([string]$scriptText)
        $tokens = $null; $errors = $null
        try {
            [System.Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$errors) | Out-Null
        } catch {
            return @{ Ok = $false; Message = "PowerShell parse exception: $($_.Exception.Message)"; Line = 0 }
        }
        if ($null -ne $errors -and @($errors).Count -gt 0) {
            $first = $errors[0]
            $line  = 0
            try { $line = [int]$first.Extent.StartLineNumber } catch { $line = 0 }
            $msg = ($errors | ForEach-Object { "PS$($_.ErrorId): $($_.Message)" }) -join "`n"
            return @{ Ok = $false; Message = $msg; Line = $line }
        }
        return @{ Ok = $true; Message = ""; Line = 0 }
    }

    # ──────────────────────────────────────────────────────────────────
    #  SYNTAX ORACLE  (returns @{ Ok; Message; Line } in FILE line-space)
    #  Uses bash -n / ruby -c / python / node. For YAML, extracts inline
    #  bash and translates the block line number back to the YAML line.
    # ──────────────────────────────────────────────────────────────────
    # Neutralize ADO pipeline macros for the shellcheck pass ONLY. In the real
    # pipeline, $(VarName) and $(System.X) are replaced by ADO BEFORE bash runs.
    # In our extracted check they look like command substitutions; shellcheck would
    # raise false positives (SC2046/SC2086-style) on them. Replace with a safe literal
    # token of identical length-class, preserving line count so error lines still map.
    function ConvertTo-ShellcheckSafe {
        param([string]$bashText)
        return ($bashText `
            -replace '\$\((?:System\.|Build\.|Agent\.)[A-Za-z0-9_.]+\)', 'ADO_SYS_MACRO' `
            -replace '\$\([A-Za-z_][A-Za-z0-9_.]*\)', 'ADO_VAR_MACRO' `
            -replace '##vso\[[^\]]*\]', '# vso-logging-command')
    }

    # ── TYPO DETECTOR ─────────────────────────────────────────────────────
    # Catches unbound-variable class errors that bash -n and shellcheck miss:
    # variables referenced with a 1-2 character difference from a defined
    # variable in the same script (e.g. $GetAppVesion vs $GetAppVersion).
    # Uses two-row Levenshtein so it never needs a full N×M matrix.

    function Get-EditDistance {
        param([string]$a, [string]$b)
        if ($a.Length -eq 0) { return $b.Length }
        if ($b.Length -eq 0) { return $a.Length }
        $prev = 0..($b.Length)
        $curr = New-Object int[] ($b.Length + 1)
        for ($i = 1; $i -le $a.Length; $i++) {
            $curr[0] = $i
            for ($j = 1; $j -le $b.Length; $j++) {
                $cost = if ($a[$i-1] -ceq $b[$j-1]) { 0 } else { 1 }
                $curr[$j] = [Math]::Min([Math]::Min($curr[$j-1]+1, $prev[$j]+1), $prev[$j-1]+$cost)
            }
            $tmp = $prev; $prev = $curr; $curr = $tmp
        }
        return $prev[$b.Length]
    }

    # ── ESLINT CROSS-VERSION INVOCATION BUILDER ──────────────────────────────
    # ESLint's CLI flags for "ignore all config files, use ONLY --rule" changed
    # across major versions (confirmed via ESLint's own docs/migration guide
    # and a real GitHub issue showing the exact working commands for each):
    #   v8.x  (eslintrc mode, the default pre-v9): --no-eslintrc
    #   v9.x  (flat config is now DEFAULT, eslintrc mode still available but
    #         needs an explicit opt-back-in): ESLINT_USE_FLAT_CONFIG=false
    #         env var + --no-eslintrc
    #   v10.x (eslintrc support REMOVED ENTIRELY): --no-config-lookup is the
    #         only valid flag; ESLINT_USE_FLAT_CONFIG has no effect
    # Passing the wrong generation's flag risks either an ignored/unrecognized
    # flag or ESLint silently picking up a real eslint.config.js/.eslintrc from
    # the repo instead of running ONLY the rules this engine specifies — so
    # this detects the actual installed version via `eslint --version` rather
    # than assuming one form works everywhere.
    #
    # eslint-plugin-react-hooks ships NO CLI binary of its own (unlike tsc/
    # vue-tsc, which Get-Command can detect directly) — it's a library only
    # loadable by ESLint itself via --plugin or a config file. Detected here
    # via node_modules/eslint-plugin-react-hooks/package.json existence, the
    # same real mechanism Node's own require.resolve() uses under the hood.
    # If absent, the hook-specific rules are simply omitted — same script,
    # correct whether or not the plugin happens to be installed.
    function Get-EslintInvocation {
        param([string]$repoRootPath, [switch]$isTypeScript)
        # CACHED: this function's entire result is stable for the rest of the run
        # (eslint's installed version, the react-hooks plugin's presence, the ts
        # parser's presence none of these change mid-script) but was being fully
        # recomputed -- including a real "eslint --version" subprocess spawn, not
        # just a Get-Command lookup -- on EVERY call. Get-SyntaxError runs once per
        # AI-fix loop iteration (up to 25x for one stubborn file per
        # $MAX_ITERS_PER_FILE), so this was up to 25 redundant subprocess spawns
        # for a single file. Cache key is isTypeScript alone since repoRootPath is
        # always $env:BUILD_SOURCESDIRECTORY at every real call site (confirmed) --
        # a fixed value for the whole job, so it can't affect the cached result.
        $cacheKey = if ($isTypeScript) { 'ts' } else { 'js' }
        if ($null -eq $script:eslintInvocationCache) { $script:eslintInvocationCache = @{} }
        if ($script:eslintInvocationCache.ContainsKey($cacheKey)) { return $script:eslintInvocationCache[$cacheKey] }

        if (-not $script:hasEslint) { $script:eslintInvocationCache[$cacheKey] = $null; return $null }
        $verOut = eslint --version 2>&1
        $verMatch = [regex]::Match("$verOut", 'v?(\d+)\.')
        if (-not $verMatch.Success) { $script:eslintInvocationCache[$cacheKey] = $null; return $null }   # can't determine version -- skip rather than guess
        $major = [int]$verMatch.Groups[1].Value

        $envOverrides = @{}
        $noConfigFlags = @()
        if ($major -le 8) {
            $noConfigFlags = @('--no-eslintrc')
        } elseif ($major -eq 9) {
            $envOverrides['ESLINT_USE_FLAT_CONFIG'] = 'false'
            $noConfigFlags = @('--no-eslintrc')
        } else {
            $noConfigFlags = @('--no-config-lookup')
        }

        $pluginAvailable = $false
        $tsParserAvailable = $false
        if (-not [string]::IsNullOrWhiteSpace($repoRootPath)) {
            $pluginPkgPath = Join-Path $repoRootPath 'node_modules/eslint-plugin-react-hooks/package.json'
            $pluginAvailable = Test-Path $pluginPkgPath
            $tsParserPkgPath = Join-Path $repoRootPath 'node_modules/@typescript-eslint/parser/package.json'
            $tsParserAvailable = Test-Path $tsParserPkgPath
        }

        # CONFIRMED VIA RESEARCH: plain eslint (default espree parser) cannot
        # parse TypeScript syntax at all -- a bare type annotation like ": number"
        # produces "Parsing error: Unexpected token :" on perfectly valid code,
        # the SAME false-positive shape as the original node-check-on-JSX bug
        # fixed earlier in this engine. So for TypeScript content, only attach
        # ESLint when @typescript-eslint/parser is confirmed present; otherwise
        # skip the eslint pass entirely (tsc-only stays correct and safe, as it
        # already is) rather than risk flagging valid TS as broken.
        if ($isTypeScript -and -not $tsParserAvailable) { return $null }
        $parserArgs = @()
        if ($isTypeScript -and $tsParserAvailable) {
            $parserArgs = @('--parser', '@typescript-eslint/parser')
        }

        $baseRules = '{"no-undef":"error","no-unused-vars":"warn"}'
        # react-hooks/exhaustive-deps stays "warn", matching React's OWN
        # documented recommendation in every official example -- never
        # escalated to "error" here, since that would override an explicit
        # upstream design choice this engine has no basis to second-guess.
        # rules-of-hooks IS "error": calling a Hook conditionally or outside
        # a component is a genuine correctness bug, not a style preference.
        $hookRuleArgs = @()
        if ($pluginAvailable) {
            $hookRuleArgs = @('--plugin', 'react-hooks', '--rule',
                '{"react-hooks/rules-of-hooks":"error","react-hooks/exhaustive-deps":"warn"}')
        }

        $result = @{
            EnvOverrides   = $envOverrides
            BaseArgs       = $noConfigFlags + $parserArgs + @('--rule', $baseRules) + $hookRuleArgs
            PluginLoaded   = $pluginAvailable
            TsParserLoaded = $tsParserAvailable
            Major          = $major
        }
        $script:eslintInvocationCache[$cacheKey] = $result
        return $result
    }

    function Get-VariableTypos {
        param([string]$content, [string]$lang)
        # Returns @{Ok=$false; Message; Line} for first likely typo found.
        # Returns @{Ok=$true} when content is clean.
        # Minimum variable length = 4 chars: edit-dist-1 on short names is noise.
        #
        # IMPORTANT: definition collection uses [regex]::Matches() (all matches on a line)
        # NOT the -match operator (first match only). Without this, a semicolon-separated
        # multi-assignment like "$braceDepth=0; $parenDepth=0; $bracketDepth=0" would only
        # register $braceDepth in $defined, causing $bracketDepth to be flagged as a typo.

        $lines = $content -split "`n"

        # ADO prefix patterns — these are pipeline-injected, never locally defined.
        $adoPrefixes = @('SYSTEM_','BUILD_','AGENT_','RELEASE_','TF_','PIPELINE_')

        # Common builtins that are never typos regardless of distance to a defined var.
        $bashBuiltins = [System.Collections.Generic.HashSet[string]]@(
            'HOME','PATH','PWD','USER','SHELL','IFS','BASH','BASH_VERSION','LINENO',
            'RANDOM','SECONDS','OLDPWD','PPID','UID','EUID','GROUPS','HOSTNAME',
            'TERM','LANG','LC_ALL','DISPLAY','EDITOR','PAGER','VISUAL','OSTYPE',
            'MACHTYPE','HOSTTYPE','TMPDIR','SHLVL','OPTIND','OPTARG','REPLY',
            'FUNCNAME','BASH_SOURCE','BASH_LINENO','BASH_REMATCH','PIPESTATUS'
        )
        $psBuiltins = [System.Collections.Generic.HashSet[string]]([System.StringComparer]::OrdinalIgnoreCase)
        @('ErrorActionPreference','WarningPreference','VerbosePreference','DebugPreference',
          'InformationPreference','ProgressPreference','PSVersionTable','PSScriptRoot',
          'PSCommandPath','PSCulture','PSUICulture','true','false','null','LASTEXITCODE',
          'Matches','Error','args','MyInvocation','PSBoundParameters','Host',
          'ExecutionContext','HOME','PATH','PWD','env','script','global','local',
          # PowerShell Core automatic read-only platform variables (cannot be assigned to).
          # Must be listed here so the typo detector does not flag them as mis-spellings
          # of user-defined variables like $onWindows / $onMac that are edit-distance 2 away.
          'IsWindows','IsMacOS','IsLinux','IsCoreCLR',
          'PID','PROFILE','ShellId','OFS','NestedPromptLevel','StackTrace',
          'ConfirmPreference','WhatIfPreference','OutputEncoding','FormatEnumerationLimit',
          'PSDefaultParameterValues','PSEmailServer','PSSessionOption',
          'PSSessionApplicationName','PSSessionConfigurationName','AllNodes') |
            ForEach-Object { [void]$psBuiltins.Add($_) }

        if ($lang -eq 'bash') {
            $defined = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($line in $lines) {
                if ($line -match '^\s*#') { continue }
                # Use Matches() not -match so ALL assignments on a semicolon-separated line are captured
                foreach ($m in ([regex]::Matches($line, '(?:^|[\s;])(?:export\s+|local\s+|declare\s+[-a-zA-Z]*\s+|readonly\s+)?([a-zA-Z_][a-zA-Z0-9_]{3,})\s*=(?!=)'))) {
                    [void]$defined.Add($m.Groups[1].Value)
                }
                if ($line -match '\bfor\s+([a-zA-Z_][a-zA-Z0-9_]{3,})\s+in\b') { [void]$defined.Add($matches[1]) }
            }
            if ($defined.Count -eq 0) { return @{ Ok = $true; Message = ''; Line = 0 } }
            $lineNum = 0
            foreach ($line in $lines) {
                $lineNum++
                if ($line -match '^\s*#') { continue }
                foreach ($ref in ([regex]::Matches($line, '\$\{?([a-zA-Z_][a-zA-Z0-9_]{3,})\}?'))) {
                    $v = $ref.Groups[1].Value
                    if ($defined.Contains($v)) { continue }
                    if ($bashBuiltins.Contains($v)) { continue }
                    if ($v -match '^(?:SYSTEM_|BUILD_|AGENT_|RELEASE_|TF_|PIPELINE_)') { continue }
                    foreach ($d in $defined) {
                        if ([Math]::Abs($v.Length - $d.Length) -gt 2) { continue }
                        # FOUND VIA ADVERSARIAL TESTING: simple singular/plural pairs ($file/$files,
                        # $item/$items, $error/$errors) sit at edit-distance 1 and are an extremely
                        # common, fully legitimate pattern (a loop var for one element of a
                        # same-named collection) -- NOT a typo. Excluded by checking for an EXACT
                        # trailing s/es relationship (verified this does not also suppress genuine
                        # typos between two plurals, e.g. "flies" vs "files", since that's a
                        # transposition WITHIN the word, not an added suffix).
                        $lv = $v.ToLowerInvariant(); $ld = $d.ToLowerInvariant()
                        if ($lv -eq "${ld}s" -or $ld -eq "${lv}s" -or $lv -eq "${ld}es" -or $ld -eq "${lv}es") { continue }
                        $dist = Get-EditDistance -a $v -b $d
                        if ($dist -ge 1 -and $dist -le 2) {
                            return @{ Ok = $false; Line = $lineNum
                                Message = "Likely variable name typo at line ${lineNum}: `$$v` — did you mean `$$d`? (edit distance $dist). Fix ONLY the variable name on this line." }
                        }
                    }
                }
            }

        } elseif ($lang -eq 'powershell') {
            $defined = [System.Collections.Generic.HashSet[string]]([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($line in $lines) {
                if ($line -match '^\s*#') { continue }
                # Use Matches() not -match — catches ALL $var= assignments on a semicolon-separated line
                foreach ($m in ([regex]::Matches($line, '(?:\[\w[\w.]*\]\s*)?\$([a-zA-Z_][a-zA-Z0-9_]{3,})\s*=(?!=)'))) { [void]$defined.Add($m.Groups[1].Value) }
                if ($line -match '\bforeach\s*\(\s*\$([a-zA-Z_][a-zA-Z0-9_]{3,})\s+in\b') { [void]$defined.Add($matches[1]) }
                foreach ($pr in ([regex]::Matches($line, '(?i)\bparam\s*\([^)]*\$([a-zA-Z_][a-zA-Z0-9_]{3,})'))) { [void]$defined.Add($pr.Groups[1].Value) }
            }
            if ($defined.Count -eq 0) { return @{ Ok = $true; Message = ''; Line = 0 } }
            $lineNum = 0
            foreach ($line in $lines) {
                $lineNum++
                if ($line -match '^\s*#') { continue }
                foreach ($ref in ([regex]::Matches($line, '(?<!\w:)\$([a-zA-Z_][a-zA-Z0-9_]{3,})'))) {
                    $v = $ref.Groups[1].Value
                    if ($defined.Contains($v)) { continue }
                    if ($psBuiltins.Contains($v)) { continue }
                    if ($v -match '^(?:SYSTEM_|BUILD_|AGENT_|RELEASE_|TF_|PIPELINE_)') { continue }
                    foreach ($d in $defined) {
                        if ([Math]::Abs($v.Length - $d.Length) -gt 2) { continue }
                        # Same plural exclusion as the bash branch above -- see that comment
                        # for the full rationale and adversarial-testing verification.
                        $lv = $v.ToLowerInvariant(); $ld = $d.ToLowerInvariant()
                        if ($lv -eq "${ld}s" -or $ld -eq "${lv}s" -or $lv -eq "${ld}es" -or $ld -eq "${lv}es") { continue }
                        $dist = Get-EditDistance -a $v -b $d
                        if ($dist -ge 1 -and $dist -le 2) {
                            return @{ Ok = $false; Line = $lineNum
                                Message = "Likely variable name typo at line ${lineNum}: `$$v` — did you mean `$$d`? (edit distance $dist). Fix ONLY the variable name on this line." }
                        }
                    }
                }
            }
        }
        return @{ Ok = $true; Message = ''; Line = 0 }
    }

    function Get-SyntaxError {
        param([string]$filePath, [string]$content)
        $tmp = Join-Path $workRoot ("chk_" + [System.IO.Path]::GetRandomFileName())
        $oldEA = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $result = @{ Ok = $true; Message = ""; Line = 0; Fallback = $false }
        try {
            if ($filePath -match '\.ya?ml$') {
                $blocks = Get-InlineScriptBlocks -yamlContent $content
                foreach ($b in $blocks) {
                    if ($b.Kind -eq 'powershell') {
                        $psr = Test-PowerShellSyntax -scriptText $b.Body
                        if (-not $psr.Ok) {
                            $yamlLine = $b.YamlStartLine + ([Math]::Max(1, $psr.Line)) - 1
                            $result = @{ Ok = $false; Message = "inline-powershell: $($psr.Message)"; Line = $yamlLine }
                            break
                        }
                        continue
                    }
                    if ($b.Kind -eq 'cmd') {
                        # Windows-targeted bare 'script:' step — runs cmd.exe, not bash.
                        # See Test-BatchSyntax above and the OS-target detection note in
                        # Get-InlineScriptBlocks for the full reasoning. Deliberately does
                        # NOT run the bash-specific typo pass below (Get-VariableTypos
                        # -lang 'bash' assumes $var syntax, not batch's %var%/!var!).
                        $btr = Test-BatchSyntax -content $b.Body
                        if (-not $btr.Ok) {
                            $yamlLine = $b.YamlStartLine + ([Math]::Max(1, $btr.Line)) - 1
                            $result = @{ Ok = $false; Message = "inline-cmd: $($btr.Message)"; Line = $yamlLine }
                            break
                        }
                        continue
                    }
                    # bash block
                    # ── BOM GUARD: strip leading U+FEFF before validation ───────────
                    # YAML-embedded scripts sometimes carry the file-level BOM as a
                    # Unicode character inside the extracted body. If written as-is,
                    # shellcheck reports SC1082 ("This file has a UTF-8 BOM") at
                    # line 1 — a non-fixable binary issue that blocks Gemini from ever
                    # seeing the REAL syntax errors (unclosed quotes, etc.).
                    # Stripping it here prevents SC1082 so the actual errors surface.
                    # The BOM character is also removed from $working below if found.
                    $scriptBody = $b.Body
                    if ($scriptBody.Length -gt 0 -and [int][char]$scriptBody[0] -eq 0xFEFF) {
                        $scriptBody = $scriptBody.Substring(1)
                        # Also strip from $working so the fixed file stays BOM-free.
                        $bomYamlLine = $b.YamlStartLine
                        $wLines = $working -split '\n'
                        if ($bomYamlLine -ge 1 -and $bomYamlLine -le $wLines.Count) {
                            $wl = $wLines[$bomYamlLine - 1]
                            if ($wl.Length -gt 0 -and [int][char]$wl[0] -eq 0xFEFF) {
                                $wLines[$bomYamlLine - 1] = $wl.Substring(1)
                                $working = $wLines -join "`n"
                            }
                        }
                    }
                    $bf = "$tmp.sh"
                    [System.IO.File]::WriteAllText($bf, $scriptBody, [System.Text.Encoding]::UTF8)
                    if ($script:hasBash) {
                        $out = bash -n $bf 2>&1
                        $code = $LASTEXITCODE
                        if ($code -eq 0 -and $script:hasShellcheck) {
                            # Deep static pass on an ADO-macro-neutralized copy. Errors only
                            # (-S error), exclude SC2154 (pipeline-injected vars look unassigned),
                            # SC2148 (no shebang inside YAML block), SC1082 (UTF-8 BOM — handled
                            # separately so it never blocks detection of REAL syntax errors like
                            # unclosed quotes, malformed ${} expansions, etc.).
                            $scf = "$tmp.sc.sh"
                            [System.IO.File]::WriteAllText($scf, (ConvertTo-ShellcheckSafe $scriptBody), [System.Text.Encoding]::UTF8)
                            $scOut = shellcheck -S error -e SC2154 -e SC2148 -e SC1082 -f gcc $scf 2>&1
                            $scCode = $LASTEXITCODE
                            Remove-Item $scf -Force -ErrorAction SilentlyContinue
                            if ($scCode -ne 0) { $out = $scOut -replace [regex]::Escape($scf), 'inline-script'; $code = 1 }
                        }
                        Remove-Item $bf -Force -ErrorAction SilentlyContinue
                    } else {
                        # BUGFIX (real incident -- THE EXACT FAILURE FROM A LIVE TEST RUN):
                        # bash was called UNCONDITIONALLY here with no guard at all. On the
                        # real Windows self-hosted agent this engine runs on, bash is not on
                        # PATH, producing "Unable to locate executable file: 'bash'" -- a
                        # terminating exception that crashed the ENTIRE engine run the moment
                        # any YAML file with an inline bash script block was processed. Falls
                        # back to structural checking (unclosed quotes/$(...)/${...}) -- the
                        # exact error class this script's own deterministic Repair-
                        # AllUnclosedDelimiters fixer targets, so even without bash itself,
                        # the most common real-world inline-bash breakage is still caught.
                        Remove-Item $bf -Force -ErrorAction SilentlyContinue
                        $st = Test-StructuralSyntax -content $scriptBody -lang 'sh'
                        if (-not $st.Ok) {
                            $yamlLine = $b.YamlStartLine + ([Math]::Max(1, $st.Line)) - 1
                            $result = @{ Ok = $false; Message = "inline-bash (structural fallback): $($st.Message)"; Line = $yamlLine }
                            break
                        }
                        $result.Fallback = $true
                        $code = 0   # already handled via $result above; suppress the generic handling below
                    }
                    if ($code -ne 0) {
                        $blockLine = 0
                        if ("$out" -match ':(\d+):' ) { $blockLine = [int]$matches[1] }
                        elseif ("$out" -match 'line (\d+)') { $blockLine = [int]$matches[1] }
                        $yamlLine = $b.YamlStartLine + $blockLine - 1
                        $result = @{ Ok = $false; Message = ("$out" -replace [regex]::Escape($bf), 'inline-script'); Line = $yamlLine }
                        break
                    }
                    # Typo pass: runs only when bash -n + shellcheck both pass.
                    # Translate block-space line number back to YAML-space.
                    $typo = Get-VariableTypos -content $b.Body -lang 'bash'
                    if (-not $typo.Ok) {
                        $result = @{ Ok = $false; Line = ($b.YamlStartLine + $typo.Line - 1); Message = $typo.Message }
                        break
                    }
                }
                # PowerShell inline block typo pass (runs after PS parser passes).
                if ($result.Ok) {
                    foreach ($b in ($blocks | Where-Object { $_.Kind -eq 'powershell' })) {
                        $typo = Get-VariableTypos -content $b.Body -lang 'powershell'
                        if (-not $typo.Ok) {
                            $result = @{ Ok = $false; Line = ($b.YamlStartLine + $typo.Line - 1); Message = $typo.Message }
                            break
                        }
                    }
                }
                # Kubernetes manifest check (NEW — see Test-KubernetesManifest
                # for full reasoning). Only runs when nothing above already
                # found a problem, and only when the content's "kind:" field
                # genuinely matches a recognized K8s resource type -- this
                # guard means an Azure DevOps pipeline YAML (which never has
                # that field) can never reach this check at all.
                if ($result.Ok -and (Test-LooksLikeKubernetesManifest -content $content)) {
                    $k8sResult = Test-KubernetesManifest -content $content
                    if (-not $k8sResult.Ok) { $result = $k8sResult }
                }
            } elseif ($filePath -match '\.sh$') {
                $bf = "$tmp.sh"; [System.IO.File]::WriteAllText($bf, $content, [System.Text.Encoding]::UTF8)
                if ($script:hasBash) {
                    $out = bash -n $bf 2>&1; $code = $LASTEXITCODE
                    if ($code -eq 0 -and $script:hasShellcheck) {
                        $scf = "$tmp.sc.sh"; [System.IO.File]::WriteAllText($scf, (ConvertTo-ShellcheckSafe $content), [System.Text.Encoding]::UTF8)
                        $scOut = shellcheck -S error -e SC2154 -e SC2148 -e SC1082 -f gcc $scf 2>&1; $scCode = $LASTEXITCODE
                        Remove-Item $scf -Force -EA SilentlyContinue
                        if ($scCode -ne 0) { $out = $scOut -replace [regex]::Escape($scf), 'script'; $code = 1 }
                    }
                    Remove-Item $bf -Force -EA SilentlyContinue
                    if ($code -ne 0) { $ln = 0; if ("$out" -match ':(\d+):') { $ln = [int]$matches[1] } elseif ("$out" -match 'line (\d+)') { $ln = [int]$matches[1] }; $result = @{ Ok=$false; Message="$out"; Line=$ln } }
                } else {
                    # BUGFIX (real incident, confirmed via live test run): bash was
                    # called UNCONDITIONALLY here with no guard at all -- on an agent
                    # without bash on PATH, this is a terminating exception that
                    # crashed the ENTIRE engine run over a single standalone .sh file.
                    Remove-Item $bf -Force -EA SilentlyContinue
                    $st = Test-StructuralSyntax -content $content -lang 'sh'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                }
                # Typo pass after bash -n + shellcheck pass.
                if ($result.Ok) {
                    $typo = Get-VariableTypos -content $content -lang 'bash'
                    if (-not $typo.Ok) { $result = @{ Ok = $false; Message = $typo.Message; Line = $typo.Line } }
                }
            } elseif ($filePath -match '(?i)(Fastfile|Gemfile|Podfile|Appfile|Matchfile|Gymfile|Scanfile|Deliverfile|Screengrabfile|Dangerfile|Mintfile|\.rb|\.gemspec|\.podspec|\.rake)$') {
                $bf = "$tmp.rb"; [System.IO.File]::WriteAllText($bf, $content)
                if ($script:hasRuby) {
                    $out = ruby -c $bf 2>&1; $code = $LASTEXITCODE; Remove-Item $bf -Force -EA SilentlyContinue
                } else {
                    # BUGFIX (real incident, confirmed via live test run): ruby was
                    # called UNCONDITIONALLY here with no guard at all -- on an agent
                    # without ruby on PATH, this is a terminating
                    # CommandNotFoundException that crashed the ENTIRE engine run.
                    # Falls back to structural checking (unclosed quotes/parens/
                    # blocks) -- can't replace ruby -c's full grammar check, but
                    # doesn't crash the run over one candidate file either.
                    Remove-Item $bf -Force -EA SilentlyContinue
                    $st = Test-StructuralSyntax -content $content -lang 'ruby'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                    $code = 0   # suppress the generic $code-based handling below; $result is already set if needed
                }
                if ($code -eq 0 -and $script:hasRuby -and $filePath -match '(?i)\.rb$' -and $script:hasRubocop -and -not [string]::IsNullOrWhiteSpace($env:BUILD_SOURCESDIRECTORY)) {
                    # ONLY genuine .rb files, NEVER Fastfile/Gemfile/Podfile/etc DSL
                    # filenames -- CONFIRMED VIA RESEARCH: fastlane's own .rubocop.yml
                    # (for their issue-bot project) explicitly disables several DEFAULT
                    # RuboCop style cops (Style/PredicateName, Style/Documentation,
                    # Style/MutableConstant, and more) specifically because they
                    # conflict with idiomatic Fastlane DSL code -- direct evidence from
                    # the tool's own primary-author ecosystem that default style rules
                    # genuinely misfire on this kind of file.
                    #
                    # ONLY runs when the project has its OWN .rubocop.yml -- proving
                    # explicit opt-in to a customized ruleset, same restraint as
                    # Checkstyle's config requirement (even though RuboCop itself has
                    # usable defaults, unlike Checkstyle -- this is about respecting
                    # the PROJECT's customization, e.g. fastlane's own disabled cops
                    # above, not about RuboCop needing a config to function at all).
                    #
                    # Searches up to repo root for .rubocop.yml (RuboCop's own real
                    # config-discovery behavior: "starts looking in the directory
                    # where the inspected file is and continues up to the root").
                    # Written to the REAL on-disk path (with guaranteed restore),
                    # not an isolated temp file -- confirmed via a real RuboCop bug
                    # (#6811) that single-file invocation can give DIFFERENT results
                    # than whole-project invocation for the identical code.
                    $hasRubocopConfig = $false
                    $rcCheckDir = Split-Path $filePath -Parent
                    for ($rcLevel = 0; $rcLevel -lt 10; $rcLevel++) {
                        $rcFullDir = if ([string]::IsNullOrWhiteSpace($rcCheckDir)) { $env:BUILD_SOURCESDIRECTORY } else { Join-Path $env:BUILD_SOURCESDIRECTORY $rcCheckDir }
                        if (Test-Path (Join-Path $rcFullDir '.rubocop.yml')) { $hasRubocopConfig = $true; break }
                        if ([string]::IsNullOrWhiteSpace($rcCheckDir) -or $rcCheckDir -eq '.') { break }
                        $rcParent = Split-Path $rcCheckDir -Parent
                        if ($rcParent -eq $rcCheckDir) { break }
                        $rcCheckDir = $rcParent
                    }
                    if ($hasRubocopConfig) {
                        $realRbPath = Join-Path $env:BUILD_SOURCESDIRECTORY $filePath
                        if (Test-Path $realRbPath) {
                            $origRbOnDisk = $null
                            try {
                                $origRbOnDisk = [System.IO.File]::ReadAllText($realRbPath)
                                [System.IO.File]::WriteAllText($realRbPath, $content)
                                $rcOut = rubocop $realRbPath 2>&1; $rcCode = $LASTEXITCODE
                                if ($rcCode -ne 0) { $out = $rcOut; $code = 1 }
                            } catch {
                                # rubocop itself failed to run -- not a code finding, leave $code as-is from ruby -c
                            } finally {
                                if ($null -ne $origRbOnDisk) { [System.IO.File]::WriteAllText($realRbPath, $origRbOnDisk) }
                            }
                        }
                    }
                }
                if ($code -ne 0) { $ln = 0; if ("$out" -match ':(\d+):') { $ln = [int]$matches[1] }; $result = @{ Ok=$false; Message="$out"; Line=$ln } }

            # ── PYTHON: syntax + semantic (undefined names, unused imports) ──
            } elseif ($filePath -match '\.py$') {
                $bf = "$tmp.py"; [System.IO.File]::WriteAllText($bf, $content)
                if ($script:hasPython3) {
                    # Layer 1: syntax
                    $out = python3 -m py_compile $bf 2>&1; $code = $LASTEXITCODE
                    if ($code -eq 0) {
                        # Layer 2: semantic — pyflakes catches undefined names, unused imports
                        # pyflakes does NOT need to execute code; it's purely static.
                        if ($script:hasPyflakes) {
                            $scOut = pyflakes $bf 2>&1; $scCode = $LASTEXITCODE
                            if ($scCode -ne 0) { $out = $scOut; $code = 1 }
                        } else {
                            # BUGFIX (real incident, confirmed via live test run):
                            # this previously ran "python3 -m pyflakes" UNCONDITIONALLY
                            # whenever python3 existed, without checking whether the
                            # pyflakes MODULE was actually installed for it. The
                            # embeddable Python distro this engine auto-installs has
                            # no pip and no pyflakes by default -- "python3 -m pyflakes"
                            # against it produces a real, non-zero-exit
                            # "ModuleNotFoundError: No module named 'pyflakes'", which
                            # got reported as if it were a bug IN THE FILE BEING
                            # CHECKED. Confirmed real consequence: the AI was asked to
                            # fix "No module named 'pyflakes'" as if it were app.py's
                            # own error, correctly declined (it's an environment
                            # problem, not a code problem it can fix by editing the
                            # file), and the run stopped there -- masking app.py's
                            # ACTUAL remaining issue (a missing import) entirely.
                            # Probe for the module's real presence FIRST, exactly the
                            # same defensive pattern used for every other optional
                            # secondary tool in this script, rather than assuming
                            # "python3 exists" implies "every python3 module exists".
                            $pyflakesProbe = python3 -c "import pyflakes" 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                $scOut = python3 -m pyflakes $bf 2>&1; $scCode = $LASTEXITCODE
                                if ($scCode -ne 0) { $out = $scOut; $code = 1 }
                            }
                            # else: pyflakes genuinely not installed for this Python --
                            # silently skip the semantic layer, exactly like the
                            # $script:hasPyflakes=false / no-fallback-available case
                            # already does elsewhere in this script. py_compile's
                            # syntax-only result (already confirmed $code=0 here)
                            # stands as the final verdict for this file.
                        }
                    }
                    Remove-Item $bf -Force -EA SilentlyContinue
                } else {
                    # BUGFIX (real incident, confirmed via live test run): python3 was
                    # called UNCONDITIONALLY here with no guard at all -- on an agent
                    # without python3 on PATH, this is a terminating
                    # CommandNotFoundException that crashed the ENTIRE engine run.
                    # Falls back to structural checking -- catches unclosed parens/
                    # brackets/quotes, but honestly cannot catch Python's indentation-
                    # based syntax errors the way py_compile would; still strictly
                    # better than crashing the whole run over one candidate file.
                    Remove-Item $bf -Force -EA SilentlyContinue
                    $st = Test-StructuralSyntax -content $content -lang 'python'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                    $code = 0   # suppress the generic $code-based handling below; $result is already set if needed
                }
                if ($code -ne 0) { $ln = 0; if ("$out" -match 'line (\d+)|\:(\d+):') { $ln = [int]($matches[1],$matches[2] | Where-Object {$_} | Select-Object -First 1) }; $result = @{ Ok=$false; Message="$out"; Line=$ln } }

            # ── TYPESCRIPT (.tsx): FULL semantic type checking via tsc --noEmit ──
            # tsc is included with Node.js on most CI agents. --noEmit means
            # it validates the file completely (types, undefined names, wrong
            # properties) without producing any output files.
            # This is the ONLY scripted language with compile-class semantic coverage.
            } elseif ($filePath -match '\.tsx$') {
                $bf = "$tmp.tsx"; [System.IO.File]::WriteAllText($bf, $content)
                if ($script:hasTsc) {
                    # BUGFIX: previously passed "--strict false". tsc's boolean flags
                    # accept ONLY the bare flag (implying true) -- there is no CLI
                    # syntax for an explicit false value (confirmed: a TypeScript
                    # GitHub issue literally requesting "--strictNullChecks=false be
                    # accepted on CLI" was never implemented). A trailing "false"
                    # token is parsed as an extra root file to compile, which doesn't
                    # exist on disk, producing "error TS6053: File 'false' not found"
                    # on EVERY invocation -- a false positive on valid code, since
                    # $code -ne 0 fires from that alone. Simply omitting any
                    # strict-related flag is correct: tsc defaults to non-strict
                    # outside an explicit tsconfig.json "strict": true.
                    $out = tsc --noEmit --allowJs --jsx react --skipLibCheck --module commonjs --target ES2020 $bf 2>&1; $code = $LASTEXITCODE
                    if ($code -ne 0) {
                        $filtered = ($out -split "\r?\n" | Where-Object { $_ -match 'error TS' }) -join "`n"
                        if (-not [string]::IsNullOrWhiteSpace($filtered)) { $out = $filtered }
                    }
                    if ($code -eq 0) {
                        $eslintInv = Get-EslintInvocation -repoRootPath $env:BUILD_SOURCESDIRECTORY -isTypeScript
                        if ($null -ne $eslintInv) {
                            $oldEnvVals = @{}
                            foreach ($k in $eslintInv.EnvOverrides.Keys) {
                                $oldEnvVals[$k] = [System.Environment]::GetEnvironmentVariable($k)
                                [System.Environment]::SetEnvironmentVariable($k, $eslintInv.EnvOverrides[$k])
                            }
                            try {
                                $scOut = eslint @($eslintInv.BaseArgs) $bf 2>&1
                                $scCode = $LASTEXITCODE
                                if ($scCode -ne 0) { $out = $scOut; $code = 1 }
                            } finally {
                                foreach ($k in $oldEnvVals.Keys) {
                                    [System.Environment]::SetEnvironmentVariable($k, $oldEnvVals[$k])
                                }
                            }
                        }
                    }
                } else {
                    # BUGFIX: the old fallback here was plain `node --check`, which CANNOT
                    # parse JSX/TSX syntax at all (confirmed: V8's bare parser reports the
                    # opening '<' of any tag as "Unexpected token", on every syntactically
                    # valid file). That made this fallback misreport every valid .tsx file
                    # as broken whenever tsc wasn't on the agent. No installed tool here can
                    # safely substitute, so this falls through to the structural brace/paren
                    # validator instead — narrower coverage, but it won't produce a false
                    # "broken" verdict on valid JSX the way node --check did.
                    $st = Test-StructuralSyntax -content $content -lang 'js'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                    $code = 0   # suppress the generic $code-based handling below; $result is already set if needed
                }
                Remove-Item $bf -Force -EA SilentlyContinue
                if ($code -ne 0) { $ln = 0; if ("$out" -match '\((\d+),\d+\):|:(\d+):') { $ln = [int]($matches[1],$matches[2] | Where-Object {$_} | Select-Object -First 1) }; $result = @{ Ok=$false; Message="$out"; Line=$ln } }

            # ── TYPESCRIPT (.ts, no JSX): same tsc --noEmit semantic checking ────
            } elseif ($filePath -match '\.ts$') {
                $bf = "$tmp.ts"; [System.IO.File]::WriteAllText($bf, $content)
                if ($script:hasTsc) {
                    # BUGFIX: see .tsx branch above for full explanation -- "--strict false"
                    # is invalid tsc CLI syntax; the trailing "false" token is parsed as
                    # an extra root file, causing a spurious TS6053 on every invocation.
                    $out = tsc --noEmit --allowJs --skipLibCheck --module commonjs --target ES2020 $bf 2>&1; $code = $LASTEXITCODE
                    if ($code -ne 0) {
                        $filtered = ($out -split "\r?\n" | Where-Object { $_ -match 'error TS' }) -join "`n"
                        if (-not [string]::IsNullOrWhiteSpace($filtered)) { $out = $filtered }
                    }
                } elseif ($script:hasNode) {
                    # Plain .ts has no JSX in it (that's what .tsx is for), so node --check
                    # is a safe fallback here -- no JSX-parsing limitation applies.
                    $out = node --check $bf 2>&1; $code = $LASTEXITCODE
                } else {
                    # BUGFIX (real incident, confirmed via live test run): this branch
                    # previously called "node --check" UNCONDITIONALLY with no guard --
                    # on an agent without Node.js on PATH, that's a terminating
                    # CommandNotFoundException that crashed the ENTIRE engine run, not
                    # just this one file. Falls back to the same structural brace/paren
                    # validator used for .tsx/.jsx when their real tools are absent.
                    Remove-Item $bf -Force -EA SilentlyContinue
                    $st = Test-StructuralSyntax -content $content -lang 'js'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                    $code = 0   # suppress the generic $code-based handling below; $result is already set if needed
                }
                if ($script:hasTsc -or $script:hasNode) { Remove-Item $bf -Force -EA SilentlyContinue }
                if ($code -ne 0) { $ln = 0; if ("$out" -match '\((\d+),\d+\):|:(\d+):') { $ln = [int]($matches[1],$matches[2] | Where-Object {$_} | Select-Object -First 1) }; $result = @{ Ok=$false; Message="$out"; Line=$ln } }

            # ── JAVASCRIPT-WITH-JSX (.jsx): tsc --jsx, NOT node --check ───────────
            # BUGFIX (confirmed via testing + multiple independent reports): node
            # --check uses V8's bare parser, which has no concept of JSX syntax.
            # It reports the opening '<' of ANY tag as "Unexpected token" -- on every
            # syntactically valid .jsx file, not just broken ones. This branch was
            # previously merged with plain .js under one '\.jsx?$' pattern, which meant
            # node --check ran against .jsx content as if it were plain JS and false-
            # flagged it every time. tsc with --allowJs --jsx react actually understands
            # JSX (this is TypeScript's own documented JS+JSX support, not a TS-only
            # feature, confirmed via the TypeScript CLI reference), so it both correctly
            # accepts valid JSX and still catches real syntax errors.
            # NOTE: an eslint-based fallback (espree's parserOptions.ecmaFeatures.jsx)
            # was considered, since espree DOES parse JSX correctly unlike node --check —
            # but no verified-working CLI syntax for passing that nested option through
            # eslint's --parser-options flag could be confirmed (its documented examples
            # only show flat key:value pairs), so it was deliberately left out rather
            # than ship an unverified invocation. If eslint is later confirmed to work
            # here, this is the place to add it back as a fallback before the structural
            # check below.
            } elseif ($filePath -match '\.jsx$') {
                $bf = "$tmp.jsx"; [System.IO.File]::WriteAllText($bf, $content)
                if ($script:hasTsc) {
                    # BUGFIX: see .tsx branch above for full explanation -- "--strict false"
                    # is invalid tsc CLI syntax; the trailing "false" token is parsed as
                    # an extra root file, causing a spurious TS6053 on every invocation.
                    $out = tsc --noEmit --allowJs --jsx react --skipLibCheck --module commonjs --target ES2020 $bf 2>&1; $code = $LASTEXITCODE
                    if ($code -ne 0) {
                        $filtered = ($out -split "\r?\n" | Where-Object { $_ -match 'error TS' }) -join "`n"
                        if (-not [string]::IsNullOrWhiteSpace($filtered)) { $out = $filtered }
                    }
                    if ($code -eq 0) {
                        # No -isTypeScript here: .jsx is plain JavaScript-with-JSX, not
                        # TypeScript -- ESLint's default espree parser handles it fine,
                        # so only the react-hooks plugin detection applies.
                        $eslintInv = Get-EslintInvocation -repoRootPath $env:BUILD_SOURCESDIRECTORY
                        if ($null -ne $eslintInv) {
                            $oldEnvVals = @{}
                            foreach ($k in $eslintInv.EnvOverrides.Keys) {
                                $oldEnvVals[$k] = [System.Environment]::GetEnvironmentVariable($k)
                                [System.Environment]::SetEnvironmentVariable($k, $eslintInv.EnvOverrides[$k])
                            }
                            try {
                                $scOut = eslint @($eslintInv.BaseArgs) $bf 2>&1
                                $scCode = $LASTEXITCODE
                                if ($scCode -ne 0) { $out = $scOut; $code = 1 }
                            } finally {
                                foreach ($k in $oldEnvVals.Keys) {
                                    [System.Environment]::SetEnvironmentVariable($k, $oldEnvVals[$k])
                                }
                            }
                        }
                    }
                } else {
                    # No tsc on this agent. Do NOT fall back to node --check here —
                    # that's the exact false-positive this whole branch exists to fix.
                    # Use the structural validator instead: it has no opinion on '<' at
                    # all (only tracks {}/()/[] and strings), so it won't misreport valid
                    # JSX as broken the way node --check would.
                    $st = Test-StructuralSyntax -content $content -lang 'js'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                    $code = 0
                }
                Remove-Item $bf -Force -EA SilentlyContinue
                if ($code -ne 0) { $ln = 0; if ("$out" -match '\((\d+),\d+\):|:(\d+):') { $ln = [int]($matches[1],$matches[2] | Where-Object {$_} | Select-Object -First 1) }; $result = @{ Ok=$false; Message="$out"; Line=$ln } }

            # ── PLAIN JAVASCRIPT (.js): syntax + eslint for semantic issues ──────
            # Unchanged from the original combined branch -- node --check is correct
            # here since plain .js has no JSX content to misparse.
            } elseif ($filePath -match '\.js$') {
                $bf = "$tmp.js"; [System.IO.File]::WriteAllText($bf, $content)
                if ($script:hasNode) {
                    $out = node --check $bf 2>&1; $code = $LASTEXITCODE
                    if ($code -eq 0) {
                        $eslintInv = Get-EslintInvocation -repoRootPath $env:BUILD_SOURCESDIRECTORY
                        if ($null -ne $eslintInv) {
                            $oldEnvVals = @{}
                            foreach ($k in $eslintInv.EnvOverrides.Keys) {
                                $oldEnvVals[$k] = [System.Environment]::GetEnvironmentVariable($k)
                                [System.Environment]::SetEnvironmentVariable($k, $eslintInv.EnvOverrides[$k])
                            }
                            try {
                                $scOut = eslint @($eslintInv.BaseArgs) $bf 2>&1
                                $scCode = $LASTEXITCODE
                                if ($scCode -ne 0) { $out = $scOut; $code = 1 }
                            } finally {
                                foreach ($k in $oldEnvVals.Keys) {
                                    [System.Environment]::SetEnvironmentVariable($k, $oldEnvVals[$k])
                                }
                            }
                        }
                    }
                    Remove-Item $bf -Force -EA SilentlyContinue
                } else {
                    # BUGFIX (real incident, confirmed via live test run): this branch
                    # previously called "node --check" UNCONDITIONALLY with no guard --
                    # on an agent without Node.js on PATH, that's a terminating
                    # CommandNotFoundException that crashed the ENTIRE engine run, not
                    # just this one file. eslint is also skipped here since it depends
                    # on a working Node toolchain in practice even when the eslint
                    # binary itself happens to be on PATH separately.
                    Remove-Item $bf -Force -EA SilentlyContinue
                    $st = Test-StructuralSyntax -content $content -lang 'js'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                    $code = 0   # suppress the generic $code-based handling below; $result is already set if needed
                }
                if ($code -ne 0) { $ln = 0; if ("$out" -match ':(\d+)') { $ln = [int]$matches[1] }; $result = @{ Ok=$false; Message="$out"; Line=$ln } }

            # ── POWERSHELL: PS Parser + PSScriptAnalyzer for semantic issues ──
            } elseif ($filePath -match '\.ps1$') {
                $psr = Test-PowerShellSyntax -scriptText $content
                if (-not $psr.Ok) { $result = @{ Ok = $false; Message = $psr.Message; Line = [Math]::Max(1, $psr.Line) } }
                if ($result.Ok -and $null -ne (Get-Command Invoke-ScriptAnalyzer -EA SilentlyContinue)) {
                    $issues = Invoke-ScriptAnalyzer -ScriptDefinition $content -Severity Error 2>$null
                    if ($null -ne $issues -and @($issues).Count -gt 0) {
                        $first = $issues[0]
                        $result = @{ Ok=$false; Message="PSScriptAnalyzer: $($first.RuleName) — $($first.Message)"; Line=$first.Line }
                    }
                }
                # Typo pass
                if ($result.Ok) {
                    $typo = Get-VariableTypos -content $content -lang 'powershell'
                    if (-not $typo.Ok) { $result = @{ Ok = $false; Message = $typo.Message; Line = $typo.Line } }
                }


            # JSON — PowerShell built-in, zero install, covers appsettings.json,
            # package.json, tsconfig, .eslintrc, launch.json etc.
            # Guard: files whose content starts with @ are ADO template variable
            # files (Adobe Analytics ADBMobileConfig-style, or release variable files)
            # that use @varName@ token-replacement syntax. They are not real JSON
            # and would always fail ConvertFrom-Json. Skip them.
            } elseif ($filePath -match '\.json$') {
                $jsonFirst = $content.TrimStart()
                if ($jsonFirst.Length -gt 0 -and $jsonFirst[0] -ne '@') {
                    try { $content | ConvertFrom-Json -Depth 100 -ErrorAction Stop | Out-Null }
                    catch {
                        $m = $_.Exception.Message; $ln = 0
                        if ($m -match '(\d+)') { $ln = [int]$matches[1] }
                        $result = @{ Ok=$false; Message="JSON syntax: $m"; Line=$ln }
                    }
                }

            # XML — PowerShell built-in. Covers .csproj, .sln, .plist, .resx,
            # .config, Maven pom.xml, AndroidManifest.xml, Info.plist, web.config
            } elseif ($filePath -match '(?i)\.(xml|csproj|sln|plist|resx|config|props|targets|xcworkspace|pbxproj)$') {
                try { [xml]$content | Out-Null }
                catch {
                    $m = $_.Exception.Message; $ln = 0
                    if ($m -match 'line (\d+)') { $ln = [int]$matches[1] }
                    elseif ($m -match ', (\d+)') { $ln = [int]$matches[1] }
                    $result = @{ Ok=$false; Message="XML syntax: $m"; Line=$ln }
                }

            # ── Android libs.versions.toml (version catalog) — TOML structural ──
            # BUGFIX (real, pre-existing latent bug found via systematic
            # ordering audit): this check MUST come before the generic
            # '\.toml$' branch below -- libs.versions.toml itself ends in
            # .toml, so the generic branch (if checked first) always wins
            # and this specific check becomes permanently unreachable dead
            # code, since PowerShell if/elseif chains stop at the first
            # true match. Confirmed this was the actual order in the
            # original file before this fix.
            # Modern Android projects use Gradle version catalogs. A malformed
            # libs.versions.toml breaks all dependency resolution silently.
            # Validate TOML structure: check for unclosed brackets/quotes and
            # duplicate keys (common when developers hand-edit the catalog).
            } elseif ($filePath -match '(?i)(libs\.versions\.toml|version-catalog.*\.toml|gradle/libs\.versions)') {
                $tomlLines = $content -split "\r?\n"
                for ($tl = 0; $tl -lt $tomlLines.Count; $tl++) {
                    $tLine = $tomlLines[$tl].Trim()
                    if ($tLine.StartsWith('#') -or [string]::IsNullOrWhiteSpace($tLine)) { continue }
                    # Detect unclosed quotes in TOML values
                    $qCount = ($tLine -replace "\\'",'').ToCharArray() | Where-Object { $_ -eq '"' } | Measure-Object | Select-Object -ExpandProperty Count
                    if ($qCount % 2 -ne 0) {
                        $result = @{ Ok=$false; Message="libs.versions.toml: unclosed string on line $($tl+1): $tLine"; Line=$tl+1 }
                        break
                    }
                    # Detect missing = in key-value pairs (outside [section] headers)
                    if ($tLine -notmatch '^\[' -and $tLine -notmatch '=' -and $tLine -notmatch '^#') {
                        $result = @{ Ok=$false; Message="libs.versions.toml: missing '=' in key-value on line $($tl+1): $tLine"; Line=$tl+1 }
                        break
                    }
                }

            # TOML — used by Rust Cargo.toml, Python pyproject.toml etc.
            # No built-in: use structural brace/quote check
            } elseif ($filePath -match '\.toml$') {
                $st = Test-StructuralSyntax -content $content -lang 'toml'
                if (-not $st.Ok) { $result = $st }

            # Swift — swiftc -parse for syntax (no type-checking/import resolution,
            # always on macOS agents), then SwiftLint for real lint checks if
            # available (see the detailed reasoning in the comment further below).
            } elseif ($filePath -match '\.swift$') {
                if ($script:hasSwiftc) {
                    $bf = "$tmp.swift"; [System.IO.File]::WriteAllText($bf, $content)
                    $out = swiftc -parse $bf 2>&1; $code = $LASTEXITCODE
                    if ($code -eq 0 -and $script:hasSwiftlint) {
                        # SwiftLint's OWN docs warn it's designed for already-compilable
                        # code ("non-compiling code can lead to unexpected and confusing
                        # results") -- only reached here because swiftc -parse already
                        # succeeded. No --strict flag: SwiftLint's default behavior
                        # already exits nonzero ONLY for error-severity violations
                        # (confirmed via SwiftLint's own GitHub issue #2130 explicitly
                        # documenting this as the existing default), so warnings
                        # correctly don't fail this check -- --strict would escalate
                        # warnings to failures too, which isn't this project's choice
                        # to make on the user's behalf. No config-file requirement
                        # issue here unlike Checkstyle: SwiftLint has real, documented
                        # sensible defaults and works correctly with zero config.
                        $scOut = swiftlint lint --path $bf 2>&1; $scCode = $LASTEXITCODE
                        if ($scCode -ne 0) { $out = $scOut; $code = 1 }
                    }
                    Remove-Item $bf -Force -EA SilentlyContinue
                    if ($code -ne 0) { $ln=0; if ("$out" -match ':(\d+):') { $ln=[int]$matches[1] }; $result=@{Ok=$false;Message="$out";Line=$ln} }
                } else {
                    $st = Test-StructuralSyntax -content $content -lang 'swift'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                }

            # Java — javac for syntax. We filter out classpath/import errors
            # (those need the full project) and only surface true syntax errors.
            } elseif ($filePath -match '(?i)\.java$|build\.gradle$') {
                # NOT ADDED (deliberate, researched): Checkstyle. Every realistic CI
                # invocation path has its own open reliability problem: the Gradle
                # task (gradlew checkstyleMain) runs from the Gradle DAEMON directory
                # as its working dir, not the project dir (a real, still-open Gradle
                # issue #13927 — even Apache Calcite's production config needs manual
                # absolute-path workarounds for this), and the standalone jar has no
                # stable, guessable path (it lives under a checksum-hashed
                # ~/.gradle/caches/modules-2/... directory that varies per machine).
                # Checkstyle also has no neutral "just check syntax" mode the way
                # Test-SqlSyntax avoids picking a SQL dialect — it REQUIRES a ruleset
                # config (-c flag), and there is no safe default to assume without
                # imposing a style choice the project never made. This doesn't fit
                # this engine's lightweight per-file check architecture the way
                # tsc/eslint/pyflakes do. Revisit only if a stable, project-relative
                # invocation becomes available.
                if ($script:hasJavac) {
                    $bf = "$tmp.java"; [System.IO.File]::WriteAllText($bf, $content)
                    $rawOut = javac -nowarn $bf 2>&1; $code = $LASTEXITCODE; Remove-Item $bf -Force -EA SilentlyContinue
                    if ($code -ne 0) {
                        # Filter semantic errors that need full classpath context
                        $synOnly = ($rawOut -split "\r?\n" | Where-Object {
                            $_ -notmatch '(?i)(cannot find symbol|package .* does not exist|import .* cannot|error: cannot access|note:)'
                        }) -join "`n"
                        if (-not [string]::IsNullOrWhiteSpace($synOnly)) {
                            $ln=0; if ($synOnly -match ':(\d+):') { $ln=[int]$matches[1] }
                            $result=@{Ok=$false;Message=$synOnly.Trim();Line=$ln}
                        }
                    }
                } else {
                    $st = Test-StructuralSyntax -content $content -lang 'java'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                }

            # C# — dotnet file-based-apps (.NET 10+) if confirmed available and
            # the file is genuinely standalone, else structural brace check.
            # CONFIRMED VIA RESEARCH: "dotnet build FILE.cs" is a real, first-
            # class feature as of .NET 10 (Microsoft's own docs), but their
            # SAME docs explicitly warn: "Don't place file-based apps within
            # the directory structure of a .csproj project. The project file's
            # implicit build files and settings can interfere with your file-
            # based app." Most real .cs files in a triaged repo DO live inside
            # an existing .csproj — the same category of constraint that made
            # running vue-tsc against an isolated copy unsafe earlier in this
            # file. So this only attempts dotnet build when: (1) dotnet is
            # confirmed present, (2) its major version is >=10 (the feature
            # doesn't exist before that), AND (3) no .csproj is found in the
            # file's own directory or any ancestor up to the repo root.
            # Otherwise — including the common in-project case — stays on the
            # structural check exactly as before: already correct and safe.
            } elseif ($filePath -match '(?i)\.cs$') {
                $useDotnet = $false
                if ($script:hasDotnet -and -not [string]::IsNullOrWhiteSpace($env:BUILD_SOURCESDIRECTORY)) {
                    $dnVerOut = dotnet --version 2>&1
                    $dnVerMatch = [regex]::Match("$dnVerOut", '^(\d+)\.')
                    if ($dnVerMatch.Success -and [int]$dnVerMatch.Groups[1].Value -ge 10) {
                        $hasNearbyCsproj = $false
                        $checkDir = Split-Path $filePath -Parent
                        for ($level = 0; $level -lt 10; $level++) {
                            $fullCheckDir = if ([string]::IsNullOrWhiteSpace($checkDir)) { $env:BUILD_SOURCESDIRECTORY } else { Join-Path $env:BUILD_SOURCESDIRECTORY $checkDir }
                            if (Test-Path $fullCheckDir) {
                                if (Get-ChildItem -Path $fullCheckDir -Filter '*.csproj' -EA SilentlyContinue | Select-Object -First 1) {
                                    $hasNearbyCsproj = $true; break
                                }
                            }
                            if ([string]::IsNullOrWhiteSpace($checkDir) -or $checkDir -eq '.') { break }
                            $parentDir = Split-Path $checkDir -Parent
                            if ($parentDir -eq $checkDir) { break }
                            $checkDir = $parentDir
                        }
                        $useDotnet = -not $hasNearbyCsproj
                    }
                }
                if ($useDotnet) {
                    $realCsPath = Join-Path $env:BUILD_SOURCESDIRECTORY $filePath
                    $origOnDisk = $null; $restoreNeeded = $false
                    try {
                        if (Test-Path $realCsPath) {
                            $origOnDisk = [System.IO.File]::ReadAllText($realCsPath)
                            [System.IO.File]::WriteAllText($realCsPath, $content)
                            $restoreNeeded = $true
                        } else {
                            [System.IO.File]::WriteAllText($realCsPath, $content)
                            $restoreNeeded = $true   # file didn't exist; still must clean up after
                        }
                        $out = dotnet build $realCsPath 2>&1; $code = $LASTEXITCODE
                        if ($code -ne 0) {
                            $ln = 0; if ("$out" -match '\((\d+),\d+\):') { $ln = [int]$matches[1] }
                            $result = @{ Ok=$false; Message="$out"; Line=$ln }
                        }
                    } catch {
                        # dotnet build itself failed to run (not a code finding) -- fall
                        # back to the structural check rather than report a tooling
                        # failure as if it were a finding about the file.
                        $st = Test-StructuralSyntax -content $content -lang 'csharp'
                        if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                    } finally {
                        if ($restoreNeeded) {
                            if ($null -ne $origOnDisk) { [System.IO.File]::WriteAllText($realCsPath, $origOnDisk) }
                            else { Remove-Item $realCsPath -Force -EA SilentlyContinue }
                        }
                    }
                } else {
                    $st = Test-StructuralSyntax -content $content -lang 'csharp'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                }

            # VB.NET / F# — file-based apps is a C#-ONLY feature (not VB/F#), so
            # these stay on the structural brace check unconditionally.
            } elseif ($filePath -match '(?i)\.(vb|fs)$') {
                $st = Test-StructuralSyntax -content $content -lang 'csharp'
                if (-not $st.Ok) { $result = $st }

            # Go — gofmt detects syntax errors; go vet finds deeper issues if available
            } elseif ($filePath -match '\.go$') {
                if ($script:hasGofmt) {
                    $bf = "$tmp.go"; [System.IO.File]::WriteAllText($bf, $content)
                    $out = gofmt $bf 2>&1; $code = $LASTEXITCODE; Remove-Item $bf -Force -EA SilentlyContinue
                    if ($code -eq 0 -and $script:hasGo -and -not [string]::IsNullOrWhiteSpace($env:BUILD_SOURCESDIRECTORY)) {
                        # CONFIRMED VIA RESEARCH: go vet against an ISOLATED single file
                        # produces spurious "undefined: X" errors for identifiers
                        # genuinely defined in OTHER files of the SAME package (a real
                        # Go core issue, #23916, documents exactly this) -- completely
                        # normal, idiomatic Go, but invisible to vet without real
                        # package context. So this writes to the file's REAL on-disk
                        # path (already inside its real package directory) rather than
                        # an isolated temp file, the same fix already applied for
                        # vue-tsc/dotnet build, with guaranteed restore via try/finally.
                        $realGoPath = Join-Path $env:BUILD_SOURCESDIRECTORY $filePath
                        if (Test-Path $realGoPath) {
                            $origGoOnDisk = $null
                            try {
                                $origGoOnDisk = [System.IO.File]::ReadAllText($realGoPath)
                                [System.IO.File]::WriteAllText($realGoPath, $content)
                                $vetOut = go vet $realGoPath 2>&1; $vetCode = $LASTEXITCODE
                                if ($vetCode -ne 0) { $out = $vetOut; $code = 1 }
                            } catch {
                                # go vet itself failed to run -- not a code finding, leave $code as-is from gofmt
                            } finally {
                                if ($null -ne $origGoOnDisk) { [System.IO.File]::WriteAllText($realGoPath, $origGoOnDisk) }
                            }
                        }
                    }
                    if ($code -ne 0) { $ln=0; if ("$out" -match ':(\d+):') { $ln=[int]$matches[1] }; $result=@{Ok=$false;Message="$out";Line=$ln} }
                } else {
                    $st = Test-StructuralSyntax -content $content -lang 'go'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                }

            # Kotlin — kotlinc if available, else structural check
            # Also handles Android build.gradle.kts (Gradle Kotlin DSL)
            } elseif ($filePath -match '\.kts?$|build\.gradle\.kts$') {
                if ($script:hasKotlinc) {
                    $bf = "$tmp.kt"; [System.IO.File]::WriteAllText($bf, $content)
                    $rawOut = kotlinc $bf 2>&1; $code = $LASTEXITCODE
                    Remove-Item $bf -Force -EA SilentlyContinue
                    if ($code -ne 0) {
                        $out = ($rawOut -split "\r?\n" | Where-Object { $_ -match 'error:' }) -join "`n"
                        if ([string]::IsNullOrWhiteSpace($out)) { $out = "$rawOut" }
                        $ln=0; if ($out -match ':(\d+):') { $ln=[int]$matches[1] }
                        $result=@{Ok=$false;Message=$out;Line=$ln}
                    }
                } else {
                    $st = Test-StructuralSyntax -content $content -lang 'kotlin'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                }

            # Android Gradle (Groovy DSL) — build.gradle, settings.gradle
            # No Groovy compiler on most agents: use structural brace/bracket/quote check
            # + pattern detection for common Android Gradle errors.
            } elseif ($filePath -match '(?i)(build\.gradle|settings\.gradle|gradle\.properties)$') {
                $st = Test-StructuralSyntax -content $content -lang 'groovy'
                if (-not $st.Ok) { $result = $st }
                if ($result.Ok) {
                    # Check for common Android Gradle mistakes: missing quotes on version strings,
                    # mismatched parentheses in dependency blocks, invalid version catalog refs
                    $gradleLines = $content -split '\r?\n'
                    for ($gi = 0; $gi -lt $gradleLines.Count; $gi++) {
                        $gl = $gradleLines[$gi]
                        # Unquoted version numbers in dependencies (e.g. implementation com.foo:bar:1.0.0 without quotes)
                        if ($gl -match "^\s*implementation\s+[a-zA-Z][\w.]+:[a-zA-Z][\w.-]+:\d" -and $gl -notmatch '"') {
                            $result = @{ Ok=$false; Message="Gradle: dependency string must be quoted (e.g. implementation 'group:artifact:version')"; Line=$gi+1 }; break
                        }
                        # Kotlin ext function called on wrong type (common DSL error)
                        if ($gl -match '^\s*versionCode\s*=?\s*"') {
                            $result = @{ Ok=$false; Message="Gradle: versionCode must be an integer, not a string"; Line=$gi+1 }; break
                        }
                    }
                }

            # PHP — syntax (php -l) + semantic (phpstan if available, using the
            # project's own phpstan.neon/.dist config when present, else --level=5)
            # phpstan catches: undefined variables, wrong types, missing methods
            # without executing the code — purely static analysis.
            } elseif ($filePath -match '\.php$') {
                if ($script:hasPhp) {
                    $bf = "$tmp.php"; [System.IO.File]::WriteAllText($bf, $content)
                    $out = php -l $bf 2>&1; $code = $LASTEXITCODE
                    Remove-Item $bf -Force -EA SilentlyContinue
                    if ($code -eq 0 -and $script:hasPhpstan -and -not [string]::IsNullOrWhiteSpace($env:BUILD_SOURCESDIRECTORY)) {
                        # BUGFIX: previously ran phpstan against an ISOLATED temp file.
                        # CONFIRMED VIA RESEARCH: PHPStan's own maintainer (GitHub
                        # discussion #10966) states "you need to analyse the whole
                        # project, otherwise you miss out on errors" -- and a real
                        # reproduced bug report (#3750) shows single-file analysis can
                        # produce FALSE NEGATIVES: a function defined in one project
                        # file and used in another reports a real error when analysed
                        # alone, but ZERO errors when analysed as part of the real
                        # project. A false negative here is worse than a false
                        # positive -- it gives false confidence rather than just noise.
                        # Fixed by analysing the REAL on-disk file (with guaranteed
                        # backup/restore), and by respecting the project's OWN
                        # phpstan.neon/.dist config if one exists (its own configured
                        # level applies) rather than always forcing --level=5
                        # regardless of an explicit project choice -- only falling
                        # back to --level=5 when no project config exists at all.
                        $realPhpPath = Join-Path $env:BUILD_SOURCESDIRECTORY $filePath
                        if (Test-Path $realPhpPath) {
                            $phpstanConfig = $null
                            foreach ($cfgName in @('phpstan.neon', 'phpstan.neon.dist', 'phpstan.dist.neon')) {
                                $cfgCandidate = Join-Path $env:BUILD_SOURCESDIRECTORY $cfgName
                                if (Test-Path $cfgCandidate) { $phpstanConfig = $cfgCandidate; break }
                            }
                            $origPhpOnDisk = $null
                            try {
                                $origPhpOnDisk = [System.IO.File]::ReadAllText($realPhpPath)
                                [System.IO.File]::WriteAllText($realPhpPath, $content)
                                if ($null -ne $phpstanConfig) {
                                    $scOut = phpstan analyse --configuration=$phpstanConfig --error-format=raw $realPhpPath 2>&1; $scCode = $LASTEXITCODE
                                } else {
                                    $scOut = phpstan analyse --level=5 --error-format=raw $realPhpPath 2>&1; $scCode = $LASTEXITCODE
                                }
                                if ($scCode -ne 0) { $out = $scOut; $code = 1 }
                            } catch {
                                # phpstan itself failed to run -- not a code finding, leave $code as-is from php -l
                            } finally {
                                if ($null -ne $origPhpOnDisk) { [System.IO.File]::WriteAllText($realPhpPath, $origPhpOnDisk) }
                            }
                        }
                    }
                    if ($code -ne 0) { $ln=0; if ("$out" -match 'on line (\d+)|:(\d+):') { $ln=[int]($matches[1],$matches[2] | Where-Object {$_} | Select-Object -First 1) }; $result=@{Ok=$false;Message="$out";Line=$ln} }
                } else {
                    $st = Test-StructuralSyntax -content $content -lang 'php'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                }

            # Dockerfile — structural check always runs (BUGFIX: previously
            # this entire branch was a no-op whenever hadolint was absent,
            # which is the case on the actual agent this engine runs on
            # today — confirmed hadolint=False in the real tool-cache log).
            # hadolint, when present, supplements with its deeper
            # best-practice/security rule set on top of this structural net.
            } elseif ($filePath -match '(?i)Dockerfile') {
                $st = Test-DockerfileSyntax -content $content
                if (-not $st.Ok) { $result = $st }
                if ($st.Ok -and $script:hasHadolint) {
                    $bf = "$tmp.Dockerfile"; [System.IO.File]::WriteAllText($bf, $content)
                    # --failure-threshold error: hadolint's plain default fails on ANY
                    # finding including info/style-level ones (confirmed via research,
                    # e.g. DL3059 "consider consolidating RUN instructions" is not a
                    # real bug) -- restricting to error-severity only matches the same
                    # restraint applied elsewhere today (react-hooks/exhaustive-deps
                    # staying warn, no --strict on SwiftLint).
                    $out = hadolint --failure-threshold error $bf 2>&1; $code = $LASTEXITCODE; Remove-Item $bf -Force -EA SilentlyContinue
                    if ($code -ne 0) { $ln=0; if ("$out" -match ':(\d+)') { $ln=[int]$matches[1] }; $result=@{Ok=$false;Message="$out";Line=$ln} }
                } elseif ($st.Ok) {
                    # Structural pass succeeded but hadolint wasn't available to
                    # run its deeper rule set -- flag as Fallback so the
                    # semantic-review AI pass (see Invoke-SemanticFallbackReview)
                    # still gets a chance to catch anything structural-only
                    # checking cannot see, exactly like every other language's
                    # real-tool-absent fallback path.
                    $result.Fallback = $true
                }

            # Terraform HCL — structural brace check first, then terraform validate
            # against the real directory if the project's own pipeline already ran
            # 'terraform init' there (see the detailed reasoning in the comment below).
            } elseif ($filePath -match '\.tf$|\.tfvars$') {
                $st = Test-StructuralSyntax -content $content -lang 'hcl'
                if (-not $st.Ok) { $result = $st }
                if ($st.Ok -and $script:hasTerraform -and -not [string]::IsNullOrWhiteSpace($env:BUILD_SOURCESDIRECTORY)) {
                    # terraform validate operates on a DIRECTORY, not a single file
                    # (confirmed via HashiCorp's own docs). Deliberately does NOT run
                    # 'terraform init' itself -- only attempts validate if a
                    # .terraform directory already exists (meaning the project's own
                    # pipeline already initialized it), avoiding the network cost of
                    # downloading providers on every check and any credential risk in
                    # a restricted CI environment. Confirmed via HashiCorp's own docs
                    # that validate itself needs no credentials and makes no provider
                    # API calls once init has already happened.
                    $tfRealDir = Split-Path (Join-Path $env:BUILD_SOURCESDIRECTORY $filePath) -Parent
                    if ((Test-Path $tfRealDir) -and (Test-Path (Join-Path $tfRealDir '.terraform'))) {
                        $realTfPath = Join-Path $env:BUILD_SOURCESDIRECTORY $filePath
                        if (Test-Path $realTfPath) {
                            $origTfOnDisk = $null
                            $didPushLocation = $false
                            try {
                                $origTfOnDisk = [System.IO.File]::ReadAllText($realTfPath)
                                [System.IO.File]::WriteAllText($realTfPath, $content)
                                Push-Location $tfRealDir
                                $didPushLocation = $true
                                $tfOut = terraform validate -no-color 2>&1; $tfCode = $LASTEXITCODE
                                if ($tfCode -ne 0) {
                                    $ln = 0; if ("$tfOut" -match 'line (\d+)') { $ln = [int]$matches[1] }
                                    $result = @{ Ok=$false; Message="$tfOut"; Line=$ln }
                                }
                            } catch {
                                # terraform validate itself failed to run -- not a code finding
                            } finally {
                                if ($didPushLocation) { Pop-Location }
                                if ($null -ne $origTfOnDisk) { [System.IO.File]::WriteAllText($realTfPath, $origTfOnDisk) }
                            }
                        }
                    }
                }

            # Groovy / Jenkinsfile — groovyc if available
            } elseif ($filePath -match '(?i)\.groovy$|Jenkinsfile') {
                if ($null -ne (Get-Command groovyc -EA SilentlyContinue)) {
                    $bf = "$tmp.groovy"; [System.IO.File]::WriteAllText($bf, $content)
                    $out = groovyc $bf 2>&1; $code = $LASTEXITCODE; Remove-Item $bf -Force -EA SilentlyContinue
                    if ($code -ne 0) { $ln=0; if ("$out" -match 'line (\d+)') { $ln=[int]$matches[1] }; $result=@{Ok=$false;Message="$out";Line=$ln} }
                } else {
                    $st = Test-StructuralSyntax -content $content -lang 'groovy'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                }

            # Rust — rustc if available, else structural brace/bracket check
            } elseif ($filePath -match '\.rs$') {
                if ($null -ne (Get-Command rustc -EA SilentlyContinue)) {
                    $bf = "$tmp.rs"; [System.IO.File]::WriteAllText($bf, $content)
                    $out = rustc --edition 2021 --crate-type lib $bf 2>&1; $code = $LASTEXITCODE
                    Remove-Item $bf -Force -EA SilentlyContinue
                    if ($code -ne 0) { $ln=0; if ("$out" -match 'error.*?(\d+):(\d+)') { $ln=[int]$matches[1] }; $result=@{Ok=$false;Message="$out";Line=$ln} }
                } else {
                    $st = Test-StructuralSyntax -content $content -lang 'rust'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                }

            # ── Makefile: tab-indentation check ─────────────────────────────────
            # The GNU make error "missing separator" fires when recipe lines use
            # SPACES instead of TABS. This is the #1 Makefile error in CI.
            # No compiler needed: pure text analysis — scan lines that follow
            # a target definition (line containing ': ') and check for leading tabs.
            } elseif ($filePath -match '(?i)(^|[/\\])Makefile$|\.mk$') {
                $mkLines = $content -split "\r?\n"
                $afterTarget = $false
                for ($mi = 0; $mi -lt $mkLines.Count; $mi++) {
                    $ml = $mkLines[$mi]
                    # A target line: starts with non-whitespace and contains ':'
                    if ($ml -match '^[^\s#%].*:' -and $ml -notmatch '^\.PHONY|^vpath|^include') {
                        $afterTarget = $true; continue
                    }
                    # A recipe line must start with a TAB — spaces cause "missing separator"
                    if ($afterTarget -and $ml -match '^( {2,}|\t)') {
                        if ($ml -match '^ ') {
                            $result = @{ Ok=$false; Message="Makefile: recipe line must start with TAB not spaces (missing separator error) — GNU make requires TAB for recipe indentation"; Line=$mi+1 }
                            break
                        }
                    }
                    # Blank line or comment resets target context
                    if ([string]::IsNullOrWhiteSpace($ml) -or $ml.TrimStart().StartsWith('#')) { $afterTarget = $false }
                }

            # ── DART / FLUTTER pubspec.yaml — already caught by YAML parser ──────
            # Additional semantic check: dart CLI if available (pure syntax pass).
            } elseif ($filePath -match '\.dart$') {
                if ($null -ne (Get-Command dart -EA SilentlyContinue)) {
                    $bf = "$tmp.dart"; [System.IO.File]::WriteAllText($bf, $content)
                    $out = dart analyze --fatal-infos $bf 2>&1; $code = $LASTEXITCODE
                    Remove-Item $bf -Force -EA SilentlyContinue
                    if ($code -ne 0) { $ln=0; if ("$out" -match ':(\d+):') { $ln=[int]$matches[1] }; $result=@{Ok=$false;Message="$out";Line=$ln} }
                } else {
                    $st = Test-StructuralSyntax -content $content -lang 'dart'
                    if (-not $st.Ok) { $result = $st } else { $result.Fallback = $true }
                }

            # ── SCSS / LESS — structural brace check ─────────────────────────────
            # sass --check or lessc --lint if available; else structural.
            } elseif ($filePath -match '\.(scss|less|sass)$') {
                $linter = if ($filePath -match '\.less$') { Get-Command lessc -EA SilentlyContinue } else { Get-Command sass -EA SilentlyContinue }
                if ($null -ne $linter) {
                    $ext = if ($filePath -match '\.less$') { '.less' } elseif ($filePath -match '\.sass$') { '.sass' } else { '.scss' }
                    $bf = "$tmp$ext"; [System.IO.File]::WriteAllText($bf, $content)
                    $out = if ($filePath -match '\.less$') { lessc --lint $bf 2>&1 } else { sass --no-source-map --style=expanded $bf 2>&1 }
                    $code = $LASTEXITCODE; Remove-Item $bf -Force -EA SilentlyContinue
                    if ($code -ne 0) { $ln=0; if ("$out" -match ':(\d+):|\bline\b.*?(\d+)') { $ln=[int]($matches[1],$matches[2] | Where-Object {$_} | Select-Object -First 1) }; $result=@{Ok=$false;Message="$out";Line=$ln} }
                } else {
                    # No sass/lessc binary on the agent — fall back to the dedicated CSS
                    # structural validator (Test-CssSyntax) rather than the generic
                    # brace-only Test-StructuralSyntax. SCSS/LESS nesting is still
                    # brace-delimited like CSS, so the same declaration-shape checks
                    # (missing ':' before '}', unterminated strings) apply directly —
                    # the brace-only version would silently miss those.
                    $st = Test-CssSyntax -content $content
                    if (-not $st.Ok) { $result = $st }
                }

            # ── PLAIN CSS — declaration-shape structural check, no toolchain ─────
            # See Test-CssSyntax above: catches unbalanced rule blocks AND the much
            # more common missing-colon / unterminated-declaration shape that a
            # brace-only counter (Test-StructuralSyntax) would pass as clean.
            } elseif ($filePath -match '\.css$') {
                $st = Test-CssSyntax -content $content
                if (-not $st.Ok) { $result = $st }

            # ── HTML — tag-stack structural check, no toolchain ──────────────────
            # See Test-HtmlSyntax above: HTML's failure mode is unclosed/mismatched
            # TAGS, not unbalanced braces, so it needs its own walker rather than
            # reusing Test-StructuralSyntax (which has no concept of a tag at all
            # and would report Ok=$true on a file missing a closing </div>).
            } elseif ($filePath -match '\.html?$') {
                $st = Test-HtmlSyntax -content $content
                if (-not $st.Ok) { $result = $st }

            # ── SQL — dialect-agnostic structural check, no toolchain ────────────
            # See Test-SqlSyntax above: deliberately checks ONLY what's confirmed
            # universal across PostgreSQL/MySQL/SQLite/T-SQL (unbalanced parens,
            # unterminated string/identifier literals) and explicitly avoids any
            # dialect-specific syntax, since picking the wrong dialect risks
            # false-flagging valid SQL as broken.
            } elseif ($filePath -match '\.sql$') {
                $st = Test-SqlSyntax -content $content
                if (-not $st.Ok) { $result = $st }

            # ── VUE SFC — real vue-tsc when available, structural fallback otherwise ─
            # See Test-VueSyntax above for the full two-tier design and why it
            # needs $filePath (to locate the real on-disk file for vue-tsc's
            # project-context resolution, with guaranteed backup/restore).
            } elseif ($filePath -match '\.vue$') {
                $vu = Test-VueSyntax -content $content -filePath $filePath
                if (-not $vu.Ok) { $result = $vu } elseif ($vu.Fallback) { $result.Fallback = $true }
            }
        } finally { $ErrorActionPreference = $oldEA }
        return $result
    }

    # ── UNIVERSAL STRUCTURAL SYNTAX VALIDATOR ───────────────────────────────
    # Works for ANY C-like language (Java, C#, Kotlin, Swift, Go, PHP, Groovy,
    # HCL/Terraform, Groovy) without needing the language toolchain installed.
    # Detects: unmatched braces {}, parens (), brackets [], and unclosed strings.
    # Correctly skips: comments (// /* */), string literals, template literals.
    # This covers the most common structural syntax errors that break CI builds
    # when no compiler is available on the triage agent.
    function Test-StructuralSyntax {
        param([string]$content, [string]$lang)
        $lines = $content -split "\r?\n"
        $braceDepth=0; $parenDepth=0; $bracketDepth=0
        # BUGFIX (real incident, confirmed via live test run): EOF checks below
        # previously reported Line=0 unconditionally -- giving the AI (and the
        # cache-key builder, "$path|$errorLine|$parserError") zero location
        # information. This meant: (1) the AI had no idea WHICH unclosed
        # delimiter to fix when several existed, and (2) once a fix WAS
        # correctly applied, if any OTHER unrelated imbalance happened to
        # exist (or the same generic message text recurred for any reason),
        # the cache key was IDENTICAL across iterations regardless of what
        # actually changed in the file -- causing the exact same already-
        # applied fix to be re-suggested and rejected as a no-op repeatedly,
        # burning 3 full iterations before giving up. Tracks the line number
        # of the OLDEST currently-open delimiter of each type (the outermost
        # nesting level still unclosed at EOF), which is almost always the
        # one a developer (or AI) actually needs to look at.
        $braceOpenLine=0; $parenOpenLine=0; $bracketOpenLine=0
        $inString=$false; $stringChar=''; $inBlockComment=$false; $lineNum=0
        foreach ($line in $lines) {
            $lineNum++; $inLineComment=$false
            for ($i=0; $i -lt $line.Length; $i++) {
                $c=$line[$i]; $nx=if($i+1 -lt $line.Length){$line[$i+1]}else{''}
                if ($inBlockComment) { if($c -eq '*' -and $nx -eq '/'){$inBlockComment=$false;$i++}; continue }
                if ($inLineComment) { break }
                if ($inString) {
                    if($c -eq '\' -and $lang -ne 'toml'){$i++;continue}
                    if($c -eq $stringChar){$inString=$false}; continue
                }
                # Line comments
                if($c -eq '/' -and $nx -eq '/'){$inLineComment=$true;break}
                if($c -eq '#' -and $lang -in @('python','ruby','sh','yaml','toml','hcl')){break}
                # Block comments
                if($c -eq '/' -and $nx -eq '*'){$inBlockComment=$true;$i++;continue}
                # Strings
                if($c -in '"',"'"){$inString=$true;$stringChar=$c;continue}
                if($c -eq '`' -and $lang -in @('kotlin','js','ts','go')){$inString=$true;$stringChar='`';continue}
                # Structure
                if($c -eq '{'){if($braceDepth -eq 0){$braceOpenLine=$lineNum};$braceDepth++}
                elseif($c -eq '}'){$braceDepth--;if($braceDepth -lt 0){return @{Ok=$false;Message="Unmatched closing '}' at line ${lineNum}";Line=$lineNum}}}
                elseif($c -eq '('){if($parenDepth -eq 0){$parenOpenLine=$lineNum};$parenDepth++}
                elseif($c -eq ')'){$parenDepth--;if($parenDepth -lt 0){return @{Ok=$false;Message="Unmatched closing ')' at line ${lineNum}";Line=$lineNum}}}
                elseif($c -eq '['){if($bracketDepth -eq 0){$bracketOpenLine=$lineNum};$bracketDepth++}
                elseif($c -eq ']'){$bracketDepth--;if($bracketDepth -lt 0){return @{Ok=$false;Message="Unmatched closing ']' at line ${lineNum}";Line=$lineNum}}}
            }
        }
        # BUGFIX (found via deep audit): every OTHER delimiter type above has
        # an EOF check (unclosed brace/paren/bracket), but $inString itself
        # was never checked at end-of-content -- meaning a genuinely
        # unterminated quote/backtick/apostrophe string running to the last
        # line of the file was silently reported Ok=true. This is exactly
        # the class of error this fallback exists to catch (the same
        # incident class as the original Line=0 cache-collision bug from
        # earlier this session), just for the one delimiter type that had
        # no closing check at all rather than a wrong one.
        if ($inString) {
            $charDesc = if ($stringChar -eq '`') { 'backtick string' } elseif ($stringChar -eq '"') { 'double-quoted string' } else { 'single-quoted string' }
            return @{Ok=$false;Message="Unclosed $charDesc opened on or before line ${lineNum} — never closed before end of file";Line=$lineNum}
        }
        if($braceDepth -ne 0){return @{Ok=$false;Message="Unclosed '{' opened at line ${braceOpenLine} — $braceDepth brace(s) never closed";Line=$braceOpenLine}}
        if($parenDepth -ne 0){return @{Ok=$false;Message="Unclosed '(' opened at line ${parenOpenLine} — $parenDepth paren(s) never closed";Line=$parenOpenLine}}
        if($bracketDepth -ne 0){return @{Ok=$false;Message="Unclosed '[' opened at line ${bracketOpenLine} — $bracketDepth bracket(s) never closed";Line=$bracketOpenLine}}
        return @{Ok=$true;Message="";Line=0}
    }

    # ── HTML STRUCTURAL VALIDATOR — tag-matching, no external toolchain ────
    # Brace-counting (Test-StructuralSyntax) is the WRONG model for HTML — HTML's
    # failure mode is unclosed/mismatched TAGS, not unbalanced {}/()/[]. A file
    # full of valid <div> nesting has zero braces; a single unclosed <div> won't
    # trip a brace counter at all. This walks the tag stream with a stack:
    #   - void elements (br, img, hr, input, meta, link, etc.) never need a close
    #   - self-closing tags (<foo />) are popped immediately
    #   - <script>/<style> bodies are skipped raw (their content isn't HTML —
    #     a `>` inside a JS comparison or CSS selector must not be parsed as a tag)
    #   - HTML comments <!-- --> are skipped so commented-out tags don't pollute
    #     the stack
    #   - a closing tag that doesn't match the top of the stack is the precise
    #     "mismatched tag" error; an empty stack at EOF with tags still open is
    #     the "unclosed tag" error
    # This catches the actual build-breaking class of HTML errors (unclosed
    # <div>, </span> with no matching <span>, etc.) that a brace-counter or a
    # lint-rule engine would either miss entirely or bury under style warnings.
    function Test-HtmlSyntax {
        param([string]$content)
        $voidElements = @('area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr','!DOCTYPE','!doctype')
        $rawTextElements = @('script','style')
        $stack = [System.Collections.Generic.List[object]]::new()
        $lines = $content -split "\r?\n"
        $lineNum = 0
        $inComment = $false
        $skipRawUntilTag = $null   # set to 'script' or 'style' while inside one of those bodies

        foreach ($line in $lines) {
            $lineNum++
            $pos = 0
            while ($pos -lt $line.Length) {
                if ($null -ne $skipRawUntilTag) {
                    # Inside <script>/<style> — look only for the matching closing tag,
                    # ignore everything else (JS/CSS content is not HTML).
                    $closeIdx = $line.IndexOf("</$skipRawUntilTag", $pos, [System.StringComparison]::OrdinalIgnoreCase)
                    if ($closeIdx -lt 0) { $pos = $line.Length; break }
                    $gtIdx = $line.IndexOf('>', $closeIdx)
                    if ($gtIdx -lt 0) { $pos = $line.Length; break }
                    $skipRawUntilTag = $null
                    # BUGFIX (found via testing): the closing tag was being consumed here
                    # but the corresponding script/style entry was never popped off $stack,
                    # leaving a phantom permanently-open tag that broke every subsequent
                    # real closing tag in the file (each one mismatched against the
                    # phantom instead of its actual opener). Pop it now, mirroring exactly
                    # what the normal closing-tag branch below does for every other tag.
                    if ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Name -in $rawTextElements) {
                        $stack.RemoveAt($stack.Count - 1)
                    }
                    $pos = $gtIdx + 1
                    continue
                }
                if ($inComment) {
                    $endIdx = $line.IndexOf('-->', $pos)
                    if ($endIdx -lt 0) { $pos = $line.Length; break }
                    $inComment = $false; $pos = $endIdx + 3; continue
                }
                $ltIdx = $line.IndexOf('<', $pos)
                if ($ltIdx -lt 0) { break }
                # Comment start
                if ($line.Substring($ltIdx).StartsWith('<!--')) { $inComment = $true; $pos = $ltIdx + 4; continue }
                $gtIdx = $line.IndexOf('>', $ltIdx)
                if ($gtIdx -lt 0) {
                    # Tag opens on this line but never closes with '>' on this line.
                    # Could legitimately continue on the next line (rare but valid for
                    # multi-line attribute lists) — only flag as an error if we reach
                    # EOF still inside an open '<' with no '>' anywhere after it.
                    if ($lineNum -eq $lines.Count) {
                        return @{Ok=$false;Message="HTML: tag opened with '<' on line $lineNum never closed with '>'";Line=$lineNum}
                    }
                    $pos = $line.Length; break
                }
                $tagContent = $line.Substring($ltIdx + 1, $gtIdx - $ltIdx - 1).Trim()
                $pos = $gtIdx + 1
                if ([string]::IsNullOrWhiteSpace($tagContent)) { continue }

                $isClosing = $tagContent.StartsWith('/')
                $isSelfClosing = $tagContent.EndsWith('/')
                $tagBody = $tagContent.TrimStart('/').TrimEnd('/').Trim()
                $tagNameMatch = [regex]::Match($tagBody, '^([a-zA-Z][a-zA-Z0-9\-]*)')
                if (-not $tagNameMatch.Success) { continue }   # not a real tag (e.g. stray '<' in text)
                $tagName = $tagNameMatch.Value.ToLower()

                if ($isClosing) {
                    if ($stack.Count -eq 0) {
                        return @{Ok=$false;Message="HTML: closing tag </$tagName> on line $lineNum has no matching opening tag";Line=$lineNum}
                    }
                    $top = $stack[$stack.Count - 1]
                    if ($top.Name -ne $tagName) {
                        # Mismatched close — report against where the unclosed tag was OPENED,
                        # since that's the line the developer needs to actually edit.
                        return @{Ok=$false;Message="HTML: <$($top.Name)> opened on line $($top.Line) was never closed — found </$tagName> on line $lineNum instead";Line=$top.Line}
                    }
                    $stack.RemoveAt($stack.Count - 1)
                    continue
                }
                if ($tagName -in $voidElements -or $isSelfClosing) { continue }  # never pushed
                if ($tagName -in $rawTextElements) {
                    $stack.Add([PSCustomObject]@{ Name = $tagName; Line = $lineNum })
                    # Raw-text elements are still pushed (so a missing </script> is
                    # still caught), but their BODY is skipped via skipRawUntilTag so
                    # JS/CSS content isn't misparsed as HTML tags.
                    $skipRawUntilTag = $tagName
                    continue
                }
                $stack.Add([PSCustomObject]@{ Name = $tagName; Line = $lineNum })
            }
        }
        if ($stack.Count -gt 0) {
            $unclosed = $stack[$stack.Count - 1]
            return @{Ok=$false;Message="HTML: <$($unclosed.Name)> opened on line $($unclosed.Line) is never closed before end of file ($($stack.Count) tag(s) still open)";Line=$unclosed.Line}
        }
        return @{Ok=$true;Message="";Line=0}
    }

    # ── CSS STRUCTURAL VALIDATOR — selector/declaration shape, no toolchain ──
    # Brace-counting alone misses the most common real CSS breakage: a
    # declaration block with mismatched braces is rare, but a missing ';'
    # between two declarations, or a property with no value, is extremely
    # common and brace-balanced (so Test-StructuralSyntax reports Ok=$true on
    # it). This walks block-by-block:
    #   - strips comments first (CSS comments are /* */ only — no // )
    #   - tracks brace depth like the structural validator, but ALSO inspects
    #     declaration lines (`property: value;`) inside rule bodies for the
    #     two failure shapes that actually break builds: a declaration with no
    #     ':' (stray text/missing colon) and an unterminated string spanning
    #     past end-of-block.
    # This intentionally does NOT flag unknown property names or vendor
    # prefixes (that's lint territory, not syntax — flagging it would produce
    # false positives on perfectly valid, if unusual, CSS) — scope is
    # structural validity only, matching the brief: real breaks, not style.
    function Test-CssSyntax {
        param([string]$content)
        # Strip CSS comments (/* ... */, possibly multi-line) BEFORE line-based
        # analysis, but preserve exact line COUNT and column positions so
        # reported line numbers stay accurate. Done with a manual character
        # scan rather than a regex MatchEvaluator scriptblock — the inline
        # scriptblock-to-delegate form is not reliably supported across every
        # PowerShell version this engine may run under (Windows/macOS/Linux
        # agents), and a plain character pass needs no delegate at all.
        $sb = [System.Text.StringBuilder]::new()
        $inBlockComment = $false
        for ($ci = 0; $ci -lt $content.Length; $ci++) {
            $cc = $content[$ci]
            $ncc = if ($ci + 1 -lt $content.Length) { $content[$ci + 1] } else { '' }
            if ($inBlockComment) {
                if ($cc -eq "`n") { [void]$sb.Append("`n") }
                elseif ($cc -eq '*' -and $ncc -eq '/') { $inBlockComment = $false; $ci++ }
                # else: drop the character (it's inside the comment) — replaced with nothing,
                # which is safe because we only need LINE count preserved, not column count,
                # for this validator's purposes (it reports line numbers, not columns).
                continue
            }
            if ($cc -eq '/' -and $ncc -eq '*') { $inBlockComment = $true; $ci++; continue }
            [void]$sb.Append($cc)
        }
        $stripped = $sb.ToString()

        $lines = $stripped -split "\r?\n"
        $braceDepth = 0
        $parenDepth = 0   # BUGFIX (found via adversarial testing): tracks parens so a ';'
                           # inside url(...), calc(...), etc. is never mistaken for a
                           # declaration boundary. Without this, a data: URI containing a
                           # semicolon (e.g. "url(data:image/png;base64,...)" — extremely
                           # common in real CSS for inline images) would have its internal
                           # ';' wrongly split the declaration in two, producing a false
                           # "missing colon" error on the second half. Same principle as
                           # already suppressing this check inside quoted strings — a ';'
                           # has no structural meaning while inside a function call's parens.
        $inString = $false; $stringChar = ''
        $lineNum = 0
        $blockStartLine = 0
        $blockBuffer = ''
        $declStartLine = 0   # line where the CURRENT (in-progress) declaration began —
                              # tracked separately from $blockStartLine so the error message
                              # points at the actual bad declaration, not just the rule's opening line.

        for ($li = 0; $li -lt $lines.Count; $li++) {
            $lineNum = $li + 1
            $line = $lines[$li]
            # A fresh declaration starts on this line if we're inside a rule body
            # and the buffer is currently empty (i.e. the previous declaration,
            # if any, already ended cleanly at a ';' or this is the first one).
            # NOTE: this per-line check alone misses a declaration that begins
            # MID-LINE (e.g. right after the '{' that opens the rule on the same
            # line, or right after an earlier ';' on that same line) — those
            # cases are covered below by stamping $declStartLine at every actual
            # reset point inside the character loop, not just here.
            if ($braceDepth -gt 0 -and [string]::IsNullOrWhiteSpace($blockBuffer)) { $declStartLine = $lineNum }
            for ($i = 0; $i -lt $line.Length; $i++) {
                $c = $line[$i]
                if ($inString) {
                    if ($c -eq '\') { $i++; continue }
                    if ($c -eq $stringChar) { $inString = $false }
                    continue
                }
                if ($c -in '"', "'") { $inString = $true; $stringChar = $c; continue }
                if ($c -eq '(') { $parenDepth++; if ($braceDepth -gt 0) { $blockBuffer += $c }; continue }
                if ($c -eq ')') { $parenDepth = [Math]::Max(0, $parenDepth - 1); if ($braceDepth -gt 0) { $blockBuffer += $c }; continue }
                if ($c -eq '{') {
                    if ($braceDepth -eq 0) {
                        # Entering a new rule body — the text just scanned on this
                        # line (and possibly prior lines) up to '{' is the SELECTOR,
                        # not a declaration, so don't validate it for ':'.
                        $blockStartLine = $lineNum
                        $blockBuffer = ''
                    }
                    $braceDepth++
                    $declStartLine = $lineNum   # the first declaration in this body starts here, even mid-line
                    continue
                }
                if ($c -eq '}') {
                    $braceDepth--
                    if ($braceDepth -lt 0) {
                        return @{Ok=$false;Message="CSS: unmatched closing '}' on line $lineNum — no corresponding '{' open";Line=$lineNum}
                    }
                    if ($braceDepth -eq 0 -and $blockBuffer.Trim().Length -gt 0) {
                        # A rule body closed with leftover, non-empty content that was
                        # never terminated by ';' or absorbed as the block's final
                        # declaration. The most common real-world cause: a declaration
                        # missing its value (e.g. "color:" with nothing after it before
                        # the closing brace) or a stray property with no colon at all.
                        # (A malformed declaration that WAS semicolon-terminated, e.g.
                        # "color red;", is already caught earlier at the ';' check below —
                        # this is specifically for the trailing/last-declaration case
                        # where there's no closing ';' before the '}'.)
                        $leftover = $blockBuffer.Trim()
                        if ($leftover -notmatch ':') {
                            return @{Ok=$false;Message="CSS: declaration '$leftover' inside rule starting line $blockStartLine has no ':' — missing property/value separator or stray text before line $lineNum";Line=$declStartLine}
                        }
                    }
                    $blockBuffer = ''
                    $declStartLine = $lineNum   # next declaration (in an outer/sibling block) starts here, even mid-line
                    continue
                }
                if ($c -eq ';' -and $braceDepth -gt 0 -and $parenDepth -eq 0) {
                    # Check the JUST-COMPLETED declaration for a colon HERE, at the
                    # semicolon, rather than only at the closing brace. Without this,
                    # a malformed mid-block declaration that's still semicolon-terminated
                    # (valid CSS shape-wise, invalid content-wise) would reset the buffer
                    # and slip through completely undetected — only a malformed LAST
                    # declaration (no trailing ';' before '}') would ever get caught.
                    # $parenDepth -eq 0 is the bugfix above: a ';' inside url()/calc() etc.
                    # must NOT be treated as ending the declaration.
                    $completedDecl = $blockBuffer.Trim()
                    if ($completedDecl.Length -gt 0 -and $completedDecl -notmatch ':') {
                        return @{Ok=$false;Message="CSS: declaration '$completedDecl' has no ':' — missing property/value separator";Line=$declStartLine}
                    }
                    $blockBuffer = ''
                    $declStartLine = $lineNum   # the NEXT declaration (possibly later on this same line) starts here
                    continue
                }
                if ($braceDepth -gt 0) { $blockBuffer += $c }
            }
            if ($braceDepth -gt 0) { $blockBuffer += "`n" }
        }
        if ($inString) {
            return @{Ok=$false;Message="CSS: string starting with $stringChar is never closed before end of file";Line=$lineNum}
        }
        if ($braceDepth -ne 0) {
            return @{Ok=$false;Message="CSS: $braceDepth rule block(s) opened with '{' starting around line $blockStartLine but never closed with '}'";Line=$blockStartLine}
        }
        return @{Ok=$true;Message="";Line=0}
    }

    # ── SQL STRUCTURAL VALIDATOR — dialect-agnostic, no toolchain ───────────
    # SQL syntax is genuinely dialect-specific (PostgreSQL "::" cast, T-SQL TOP
    # vs MySQL/Postgres LIMIT, MySQL backtick identifiers vs ANSI double-quote,
    # SQLite's relaxed typing, etc.) — confirmed via multiple independent SQL
    # validator references. Picking a dialect to validate against risks two
    # failure modes: false-flagging valid dialect-specific syntax as broken, or
    # being so permissive it catches nothing. Rather than guess a dialect, this
    # checks ONLY what every reference confirms is universal across ALL
    # dialects: unbalanced parentheses and unterminated string/identifier
    # literals — both explicitly called out as dialect-independent "standard
    # checks" distinct from anything dialect-specific.
    #
    # Quote-escaping note: SQL's standard way to embed a literal quote inside a
    # string is to DOUBLE it ('O''Brien'), not backslash-escape it like C-like
    # languages. Using a backslash-escape rule here (copied from the CSS/HTML
    # validators) would be WRONG for SQL and would misfire on common names —
    # this tracks the doubled-quote convention specifically.
    #
    # PostgreSQL dollar-quoting ($$...$$ or $tag$...$tag$, used for multi-line
    # strings and procedural code bodies) IS recognized — see the nested
    # Test-DollarQuoteOpen helper below. Confirmed via PostgreSQL's own docs:
    # a tag is empty or starts with a letter/underscore, contains only
    # letters/digits/underscores, no $; content between matching delimiters is
    # FULLY LITERAL (no escaping at all, not even backslashes); different-tag
    # nesting is valid and explicitly supported (the documented pattern for
    # writing function bodies, e.g. $function$...$q$...$q$...$function$).
    # Requiring a closing $ immediately after the tag characters is what
    # correctly distinguishes a real opener from an unrelated single $ (e.g.
    # a positional parameter like $1, which has no second $ right after the
    # digit) — verified via testing against exactly that case.
    #
    # Deliberately NOT checked (out of scope, same "real breaks, not style"
    # principle as the CSS validator): missing trailing semicolon (valid to
    # omit for a single statement in most engines — flagging it would be a
    # false positive against real, working SQL) and any dialect-specific
    # keyword/operator choice.
    function Test-SqlSyntax {
        param([string]$content)
        $parenDepth = 0
        $inSingle = $false; $inDouble = $false
        $inBlockComment = $false; $inLineComment = $false
        $lineNum = 1
        $parenOpenLine = 0
        $dollarQuoteStack = [System.Collections.Generic.List[object]]::new()  # stack of @{Tag=...; Line=...}

        # Checks whether $content[$idx] starts a valid PostgreSQL dollar-quote
        # opener ($tag$ where tag is empty or letter/underscore-led, alnum/
        # underscore only, no $ — confirmed via PostgreSQL's own docs). Requires
        # a closing $ immediately after the tag characters, which is exactly what
        # distinguishes a real opener from an unrelated single $ (e.g. a
        # positional parameter like $1 — that has no second $ right after the
        # digit, so it correctly never matches this pattern). Returns
        # @{Tag=...; AfterIndex=...} or $null.
        function Test-DollarQuoteOpen {
            param([string]$s, [int]$idx)
            if ($s[$idx] -ne '$') { return $null }
            $j = $idx + 1
            $tagStart = $j
            while ($j -lt $s.Length -and ($s[$j] -match '[A-Za-z0-9_]')) { $j++ }
            if ($j -lt $s.Length -and $s[$j] -eq '$') {
                $tag = $s.Substring($tagStart, $j - $tagStart)
                if ($tag -eq '' -or $tag[0] -match '[A-Za-z_]') {
                    return @{Tag=$tag; AfterIndex=$j + 1}
                }
            }
            return $null
        }

        $i = 0
        while ($i -lt $content.Length) {
            $c = $content[$i]
            $nc = if ($i + 1 -lt $content.Length) { $content[$i + 1] } else { '' }

            if ($c -eq "`n") { $lineNum++; $inLineComment = $false; $i++; continue }
            if ($inLineComment) { $i++; continue }
            if ($inBlockComment) {
                if ($c -eq '*' -and $nc -eq '/') { $inBlockComment = $false; $i += 2; continue }
                $i++; continue
            }
            if ($inSingle) {
                if ($c -eq "'" -and $nc -eq "'") { $i += 2; continue }   # '' escape -- stays inside the string
                if ($c -eq "'") { $inSingle = $false }
                $i++; continue
            }
            if ($inDouble) {
                if ($c -eq '"' -and $nc -eq '"') { $i += 2; continue }   # "" escape -- stays inside the identifier
                if ($c -eq '"') { $inDouble = $false }
                $i++; continue
            }
            if ($dollarQuoteStack.Count -gt 0) {
                # Inside a dollar-quoted block: content is FULLY LITERAL per
                # PostgreSQL's own rules ("no characters inside a dollar-quoted
                # string are ever escaped... Backslashes are not special, and
                # neither are dollar signs, unless they are part of a sequence
                # matching the opening tag") — so no quote/comment/paren
                # tracking happens in here, ONLY watch for a $ that might close
                # the current tag or open a NESTED different-tag dollar-quote.
                $dq = Test-DollarQuoteOpen -s $content -idx $i
                if ($null -ne $dq) {
                    $currentTag = $dollarQuoteStack[$dollarQuoteStack.Count - 1].Tag
                    if ($dq.Tag -eq $currentTag) {
                        $dollarQuoteStack.RemoveAt($dollarQuoteStack.Count - 1)
                        $i = $dq.AfterIndex; continue
                    } else {
                        # Different tag while already inside one — valid nesting.
                        [void]$dollarQuoteStack.Add(@{Tag=$dq.Tag; Line=$lineNum})
                        $i = $dq.AfterIndex; continue
                    }
                }
                $i++; continue
            }
            # Not inside any string/comment/dollar-quote -- check for entering one, or structure
            if ($c -eq '-' -and $nc -eq '-') { $inLineComment = $true; $i += 2; continue }
            if ($c -eq '/' -and $nc -eq '*') { $inBlockComment = $true; $i += 2; continue }
            if ($c -eq "'") { $inSingle = $true; $i++; continue }
            if ($c -eq '"') { $inDouble = $true; $i++; continue }
            if ($c -eq '$') {
                $dq = Test-DollarQuoteOpen -s $content -idx $i
                if ($null -ne $dq) {
                    [void]$dollarQuoteStack.Add(@{Tag=$dq.Tag; Line=$lineNum})
                    $i = $dq.AfterIndex; continue
                }
            }
            if ($c -eq '(') {
                if ($parenDepth -eq 0) { $parenOpenLine = $lineNum }
                $parenDepth++; $i++; continue
            }
            if ($c -eq ')') {
                $parenDepth--
                if ($parenDepth -lt 0) {
                    return @{Ok=$false;Message="SQL: unmatched closing ')' on line $lineNum";Line=$lineNum}
                }
                $i++; continue
            }
            $i++
        }

        if ($dollarQuoteStack.Count -gt 0) {
            $unclosed = $dollarQuoteStack[$dollarQuoteStack.Count - 1]
            $tagDisp = if ($unclosed.Tag -eq '') { '$$' } else { "`$$($unclosed.Tag)`$" }
            return @{Ok=$false;Message="SQL: unterminated dollar-quoted string ($tagDisp) opened on line $($unclosed.Line) — never closed before end of file";Line=$unclosed.Line}
        }
        if ($inSingle) {
            return @{Ok=$false;Message="SQL: unterminated string literal (single-quoted) — never closed before end of file.";Line=$lineNum}
        }
        if ($inDouble) {
            return @{Ok=$false;Message="SQL: unterminated quoted identifier (double-quoted) — never closed before end of file";Line=$lineNum}
        }
        if ($inBlockComment) {
            return @{Ok=$false;Message="SQL: block comment opened with /* never closed with */ before end of file";Line=$lineNum}
        }
        if ($parenDepth -ne 0) {
            return @{Ok=$false;Message="SQL: $parenDepth parenthesis/parentheses opened around line $parenOpenLine never closed";Line=$parenOpenLine}
        }
        return @{Ok=$true;Message="";Line=0}
    }

    # ── DOCKERFILE STRUCTURAL VALIDATOR — fallback when hadolint absent ────
    # BUGFIX (real gap found via audit): the existing Dockerfile check ONLY
    # runs if $script:hasHadolint is true. On the actual agent this engine
    # has been verified against, hadolint=False (confirmed in the real
    # [INFO] Tool cache log line) -- meaning Dockerfile checking has been
    # COMPLETELY INERT on every real run so far: $result stays at its
    # default Ok=$true regardless of what's actually in the file. This
    # mirrors the exact "Fallback=$true" pattern used for every other
    # language in this script when its real tool is unavailable -- it is
    # NOT a replacement for hadolint's deep best-practice/security rules,
    # only a structural net for the same class of error this script already
    # repairs everywhere else (unclosed quotes/brackets, malformed JSON).
    #
    # Rules checked, each confirmed via current Docker documentation/
    # community sources (see prior research): (1) a Dockerfile must start
    # with FROM, with ARG as the ONLY instruction permitted before it
    # (confirmed: "a valid Dockerfile must start with a FROM instruction...
    # ARG is the only instruction that may precede FROM"); (2) every
    # non-comment, non-blank line must begin with a recognized instruction
    # keyword (confirmed against Docker's own complete instruction list);
    # (3) exec-form arguments (the [...] JSON-array form used by RUN, CMD,
    # ENTRYPOINT, SHELL) must be valid JSON -- confirmed directly from
    # Docker's own reference: "you must escape backslashes... otherwise
    # treated as shell form due to not being valid JSON and fail in an
    # unexpected way" -- exactly the kind of silent failure a structural
    # check can catch before the daemon ever sees it; (4) a line-continuation
    # backslash must be followed by at least one more instruction line, not
    # be the literal last line of the file (confirmed: "no trailing
    # backslash on last line" is the fix for this exact build failure);
    # (5) unterminated quotes within a single instruction.
    function Test-DockerfileSyntax {
        param([string]$content)
        $lines = $content -split "\r?\n"

        # Confirmed against Docker's own complete instruction reference.
        # ONBUILD is a meta-instruction wrapping another instruction on the
        # SAME line (e.g. "ONBUILD RUN ..."), so it's valid as a line-leading
        # keyword on its own as well as everything after it being re-checked
        # against this same list.
        $validInstructions = @(
            'FROM','RUN','CMD','LABEL','EXPOSE','ENV','ADD','COPY','ENTRYPOINT',
            'VOLUME','USER','WORKDIR','ARG','ONBUILD','STOPSIGNAL','HEALTHCHECK',
            'SHELL','MAINTAINER'   # MAINTAINER is deprecated but still valid syntax
        )

        $seenRealInstruction = $false   # true once any non-ARG instruction is seen
        $sawFrom = $false
        $lineNum = 0
        $continuedFromPrevious = $false
        $lastNonBlankLine = 0

        foreach ($rawLine in $lines) {
            $lineNum++
            $line = $rawLine.TrimEnd("`r")
            $trimmed = $line.Trim()

            # Parser directives (e.g. "# syntax=docker/dockerfile:1") and
            # plain comments both start with '#' -- confirmed: "Docker
            # treats lines that begin with # as a comment, unless the line
            # is a valid parser directive" -- either way, skip structural
            # checks on this line; it can't itself break the build.
            if ($trimmed -eq '' -or $trimmed.StartsWith('#')) {
                if ($continuedFromPrevious -and $trimmed -eq '') {
                    # A blank line immediately after a trailing backslash is
                    # itself a malformed continuation -- nothing to continue.
                    return @{Ok=$false;Message="Dockerfile: line $($lineNum-1) ends with a line-continuation backslash ('\') but is followed by a blank line — remove the trailing backslash or add the continued content";Line=$lineNum-1}
                }
                continue
            }

            $lastNonBlankLine = $lineNum

            if ($continuedFromPrevious) {
                # This line is a CONTINUATION of the previous instruction
                # (joined by a trailing backslash) -- it does not need to
                # start with a recognized instruction keyword itself.
                $continuedFromPrevious = $trimmed.EndsWith('\')
                continue
            }

            # Extract the leading keyword (case-insensitive per Docker's own
            # spec — instructions are conventionally uppercase but Docker
            # accepts any case).
            if ($trimmed -notmatch '^([A-Za-z]+)(\s|$)') {
                return @{Ok=$false;Message="Dockerfile: line $lineNum does not start with a recognized instruction keyword (e.g. FROM, RUN, COPY) — '$trimmed' is not valid Dockerfile syntax here";Line=$lineNum}
            }
            $keyword = $matches[1].ToUpper()
            if ($keyword -notin $validInstructions) {
                return @{Ok=$false;Message="Dockerfile: line $lineNum starts with '$($matches[1])', which is not a recognized Dockerfile instruction — check for a typo (e.g. 'FORM' instead of 'FROM', 'CMS' instead of 'CMD')";Line=$lineNum}
            }

            if ($keyword -eq 'FROM') { $sawFrom = $true }
            elseif ($keyword -ne 'ARG' -and -not $sawFrom) {
                # Confirmed: ARG is the ONLY instruction permitted before
                # FROM. Anything else here means the Dockerfile is missing
                # its required first FROM instruction.
                return @{Ok=$false;Message="Dockerfile: line $lineNum ('$keyword') appears before any FROM instruction — a valid Dockerfile must start with FROM (ARG is the only instruction allowed to precede it)";Line=$lineNum}
            }
            $seenRealInstruction = $true

            # Exec-form check: if this instruction's argument portion starts
            # with '[', confirmed it must be valid JSON or Docker silently
            # misinterprets it as shell form and fails unexpectedly.
            $argPart = $trimmed.Substring($matches[0].Length).TrimStart()
            if ($argPart.StartsWith('[')) {
                # Multi-line exec-form arrays are rare but technically legal
                # if continued with a backslash; only attempt JSON validation
                # when this line's bracket is genuinely self-contained
                # (ends with ']', optionally followed by trailing whitespace
                # or a comment) -- otherwise skip rather than false-positive
                # on a legitimately multi-line array.
                if ($argPart.TrimEnd() -match '\]\s*$') {
                    try {
                        $null = $argPart | ConvertFrom-Json -ErrorAction Stop
                    } catch {
                        return @{Ok=$false;Message="Dockerfile: line $lineNum — '$keyword' uses exec form (starts with '[') but its argument is not valid JSON ($($_.Exception.Message)). Docker requires exec-form arguments to be a valid JSON array, e.g. [`"executable`", `"arg1`"], or it silently falls back to shell form and may fail unexpectedly";Line=$lineNum}
                    }
                }
            }

            # Unterminated-quote check on this single logical line (does not
            # span continuations -- each physical line's quotes must balance
            # on their own, since shell-form arguments are still just text
            # to the Dockerfile parser itself, not interpreted shell).
            # BUGFIX: a naive "-eq" character count would FALSE-POSITIVE on
            # any perfectly valid line containing an apostrophe inside a
            # double-quoted value -- e.g. LABEL description="Bob's app" has
            # an ODD raw count of single quotes (just one), but it is not
            # broken; the apostrophe is plain text inside an already-closed
            # double-quoted string. Walking the line and only toggling each
            # quote type's "open" state when NOT already inside the OTHER
            # quote type correctly treats "Bob's" as balanced (the lone "'"
            # never toggles single-quote state because it's inside an open
            # double-quote span) while still catching genuinely unclosed
            # quotes of either kind.
            $inDq = $false; $inSq = $false
            foreach ($ch in $trimmed.ToCharArray()) {
                if ($ch -eq '"' -and -not $inSq) { $inDq = -not $inDq }
                elseif ($ch -eq "'" -and -not $inDq) { $inSq = -not $inSq }
            }
            if ($inDq) {
                return @{Ok=$false;Message="Dockerfile: line $lineNum has an unclosed double quote (`"`") — likely an unclosed string in the '$keyword' instruction";Line=$lineNum}
            }
            if ($inSq) {
                return @{Ok=$false;Message="Dockerfile: line $lineNum has an unclosed single quote (') — likely an unclosed string in the '$keyword' instruction";Line=$lineNum}
            }

            $continuedFromPrevious = $trimmed.EndsWith('\')
        }

        if ($continuedFromPrevious) {
            # Confirmed: "no trailing backslash on last line" — a backslash
            # on the literal final non-blank line has nothing left to
            # continue onto and is itself the malformed state.
            return @{Ok=$false;Message="Dockerfile: line $lastNonBlankLine ends with a line-continuation backslash ('\') but is the last line of the file — remove the trailing backslash";Line=$lastNonBlankLine}
        }
        if (-not $seenRealInstruction) {
            return @{Ok=$false;Message="Dockerfile: no instructions found — a valid Dockerfile must contain at least a FROM instruction";Line=0}
        }
        if (-not $sawFrom) {
            return @{Ok=$false;Message="Dockerfile: no FROM instruction found anywhere in the file — every valid Dockerfile must have at least one FROM";Line=0}
        }
        return @{Ok=$true;Message="";Line=0}
    }

    # ── KUBERNETES MANIFEST VALIDATOR — narrow, high-confidence checks ─────
    # NEW CAPABILITY (not a fallback for any existing real tool — there was
    # no K8s coverage of any kind before this). Deliberately NARROW in
    # scope: this is NOT a schema validator (that needs a real schema
    # database the way kubeconform/kubectl --dry-run=server have, and
    # guessing at the full field set per kind+apiVersion would risk false-
    # positiving on legitimate fields this script doesn't know about — far
    # worse than missing a rare error). It checks only the handful of rules
    # confirmed via research to be both extremely common AND checkable with
    # certainty from plain text: presence of the three universally-required
    # top-level fields (confirmed: "every Kubernetes manifest" needs
    # apiVersion, kind, and metadata.name), and the selector/label mismatch
    # (confirmed as one of the most common real rejection causes: "a
    # Deployment's selector does not match the labels on its Pod template").
    #
    # SAFETY: only runs on files that already look like a genuine K8s
    # manifest -- a recognized top-level "kind:" value -- so this can NEVER
    # fire on Azure DevOps pipeline YAML (which has no such field) or any
    # other unrelated YAML file in the repo. Call sites must check
    # Test-LooksLikeKubernetesManifest BEFORE calling this, exactly the same
    # opt-in-by-content-shape pattern as the Vue/CSS/HCL checkers above.
    function Test-LooksLikeKubernetesManifest {
        param([string]$content)
        $k8sKinds = @(
            'Pod','Service','Deployment','ReplicaSet','StatefulSet','DaemonSet','Job','CronJob',
            'ConfigMap','Secret','Ingress','PersistentVolumeClaim','PersistentVolume','Namespace',
            'ServiceAccount','Role','RoleBinding','ClusterRole','ClusterRoleBinding','NetworkPolicy',
            'HorizontalPodAutoscaler','PodDisruptionBudget','StorageClass','Endpoints','LimitRange',
            'ResourceQuota','CustomResourceDefinition'
        )
        foreach ($line in ($content -split "\r?\n")) {
            if ($line -match "^kind:\s*[`"']?(\w+)[`"']?\s*`$") {
                if ($matches[1] -in $k8sKinds) { return $true }
            }
        }
        return $false
    }

    function Test-KubernetesManifest {
        param([string]$content)
        $lines = $content -split "\r?\n"

        function Get-LineIndent { param([string]$l) ($l.Length - $l.TrimStart(' ').Length) }

        $hasApiVersion = $false; $hasKind = $false; $kindValue = $null
        foreach ($line in $lines) {
            if ((Get-LineIndent $line) -ne 0) { continue }   # only top-level keys
            if ($line -match '^apiVersion:\s*\S') { $hasApiVersion = $true }
            if ($line -match "^kind:\s*[`"']?(\w+)") { $hasKind = $true; $kindValue = $matches[1] }
        }
        if (-not $hasKind) {
            return @{Ok=$false;Message="Kubernetes manifest: missing required top-level 'kind' field — every manifest must declare what resource type it defines (Deployment, Service, ConfigMap, etc.)";Line=1}
        }
        if (-not $hasApiVersion) {
            return @{Ok=$false;Message="Kubernetes manifest: missing required top-level 'apiVersion' field for kind '$kindValue'";Line=1}
        }

        # metadata.name presence: find the top-level "metadata:" block, then
        # look one indent level deeper for a "name:" key with a real value.
        $metadataIndent = $null
        $foundName = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($null -eq $metadataIndent) {
                if ($line -match '^metadata:\s*$') { $metadataIndent = Get-LineIndent $line }
                continue
            }
            if ($line.Trim() -eq '') { continue }
            $ind = Get-LineIndent $line
            if ($ind -le $metadataIndent) { break }   # left the metadata: block
            if ($ind -eq ($metadataIndent + 2) -and $line -match '^\s*name:\s*\S') { $foundName = $true; break }
        }
        if ($null -eq $metadataIndent) {
            return @{Ok=$false;Message="Kubernetes manifest (kind: $kindValue): missing required top-level 'metadata' field";Line=1}
        }
        if (-not $foundName) {
            return @{Ok=$false;Message="Kubernetes manifest (kind: $kindValue): 'metadata' block is missing the required 'name' field";Line=1}
        }

        # Selector/label mismatch -- confirmed one of the most common real
        # rejection causes for Deployment/StatefulSet/DaemonSet/ReplicaSet.
        # Only checked for these 4 kinds, which are the only ones with both
        # a spec.selector.matchLabels AND a spec.template.metadata.labels.
        if ($kindValue -in @('Deployment','StatefulSet','DaemonSet','ReplicaSet')) {
            $matchLabels = @{}
            $templateLabels = @{}
            $inMatchLabels = $false; $matchLabelsIndent = -1
            $inTemplate = $false; $inTemplateMeta = $false; $inTemplateLabels = $false; $templateLabelsIndent = -1
            foreach ($line in $lines) {
                if ($line.Trim() -eq '') { continue }
                $ind = Get-LineIndent $line
                $trimmed = $line.Trim()

                if ($trimmed -eq 'matchLabels:') { $inMatchLabels = $true; $matchLabelsIndent = $ind; continue }
                if ($inMatchLabels) {
                    if ($ind -le $matchLabelsIndent) { $inMatchLabels = $false }
                    elseif ($trimmed -match '^([\w.\-/]+):\s*"?''?([\w.\-]+)"?''?\s*$') { $matchLabels[$matches[1]] = $matches[2] }
                }

                if ($trimmed -eq 'template:' -and -not $inTemplate) { $inTemplate = $true; continue }
                if ($inTemplate -and $trimmed -eq 'metadata:' -and -not $inTemplateMeta) { $inTemplateMeta = $true; continue }
                if ($inTemplateMeta -and $trimmed -eq 'labels:' -and -not $inTemplateLabels) { $inTemplateLabels = $true; $templateLabelsIndent = $ind; continue }
                if ($inTemplateLabels) {
                    if ($ind -le $templateLabelsIndent) { $inTemplateLabels = $false; $inTemplateMeta = $false }
                    elseif ($trimmed -match '^([\w.\-/]+):\s*"?''?([\w.\-]+)"?''?\s*$') { $templateLabels[$matches[1]] = $matches[2] }
                }
            }
            foreach ($key in $matchLabels.Keys) {
                $expected = $matchLabels[$key]
                if ($templateLabels[$key] -ne $expected) {
                    return @{Ok=$false;Message="Kubernetes manifest (kind: $kindValue): spec.selector.matchLabels has '$key`: $expected' but the pod template's metadata.labels does not have a matching '$key`: $expected' — Deployment/StatefulSet/DaemonSet/ReplicaSet requires these to match exactly, or the API server rejects the resource";Line=1}
                }
            }
        }

        return @{Ok=$true;Message="";Line=0}
    }

    # ── VUE SFC VALIDATOR — real tool when available, structural fallback ───
    # Two-tier design so the SAME script works correctly whether or not
    # vue-tsc is installed on a given developer's machine — detected at
    # runtime, never assumed either way.
    #
    # TIER 1 (real tool): vue-tsc is a wrapper around tsc that understands
    # .vue Single File Components. CONFIRMED VIA RESEARCH this must NOT be
    # run against an isolated single-file copy the way .ts/.tsx are in this
    # engine — a real vue-tsc GitHub issue (vuejs/language-tools#3233)
    # documents that running it against a lone file path breaks tsconfig.json
    # / path-alias resolution and produces spurious "Cannot find module"
    # errors unrelated to the actual file's correctness. So instead of writing
    # to the usual flat temp file, this writes the candidate content directly
    # to the file's REAL location inside the actual repo checkout
    # ($env:BUILD_SOURCESDIRECTORY), runs vue-tsc there so project context
    # resolves correctly, then UNCONDITIONALLY restores the original content
    # afterward — wrapped in try/finally so the real file is never left
    # modified even if vue-tsc throws or the script is interrupted.
    #
    # TIER 2 (structural fallback, when vue-tsc isn't installed): extracts
    # the <template>/<script>/<style> blocks and validates each with the
    # SAME validators already used elsewhere in this engine — Test-HtmlSyntax
    # for <template> (verified via testing that Vue's directive/interpolation
    # syntax — v-if, :bind, @click, {{ }} — does not confuse the tag-stack
    # walker, since comparison operators and braces inside a quoted attribute
    # value never leave the "inside this tag" state), Test-StructuralSyntax
    # for <script>/<script setup> (same brace/paren/bracket counter already
    # used for every C-like language without a dedicated real-tool path), and
    # Test-CssSyntax for <style>. This catches real structural breaks (an
    # unclosed template tag, an unclosed script brace) without needing the
    # Vue-specific type-checking that only the real tool can provide.
    function Test-VueSyntax {
        param([string]$content, [string]$filePath = '')

        $vueTscAvailable = $script:hasVueTsc
        $repoRoot = $env:BUILD_SOURCESDIRECTORY
        if ($vueTscAvailable -and -not [string]::IsNullOrWhiteSpace($filePath) -and -not [string]::IsNullOrWhiteSpace($repoRoot)) {
            $realPath = Join-Path $repoRoot $filePath
            if (Test-Path $realPath) {
                $originalOnDisk = $null
                $restoreNeeded  = $false
                try {
                    $originalOnDisk = [System.IO.File]::ReadAllText($realPath)
                    [System.IO.File]::WriteAllText($realPath, $content)
                    $restoreNeeded = $true
                    $out = vue-tsc --noEmit --skipLibCheck $realPath 2>&1; $code = $LASTEXITCODE
                    if ($code -ne 0) {
                        $filtered = ($out -split "\r?\n" | Where-Object { $_ -match 'error TS' }) -join "`n"
                        if (-not [string]::IsNullOrWhiteSpace($filtered)) {
                            $firstLine = ($filtered -split "\r?\n")[0]
                            $lineMatch = [regex]::Match($firstLine, ':(\d+):\d+')
                            $lineNum = if ($lineMatch.Success) { [int]$lineMatch.Groups[1].Value } else { 1 }
                            return @{Ok=$false;Message=$filtered;Line=$lineNum}
                        }
                    }
                    return @{Ok=$true;Message="";Line=0}
                } catch {
                    # vue-tsc invocation itself failed (not a syntax finding) — fall
                    # through to the structural validator below rather than report
                    # a tooling failure as if it were a finding about the file.
                } finally {
                    if ($restoreNeeded -and $null -ne $originalOnDisk) {
                        [System.IO.File]::WriteAllText($realPath, $originalOnDisk)
                    }
                }
            }
        }

        # TIER 2: structural fallback (vue-tsc unavailable, or the real-path
        # write/restore path above wasn't usable for this candidate).
        $templateMatch = [regex]::Match($content, '(?s)<template[^>]*>(.*?)</template>')
        if ($templateMatch.Success) {
            $templateLineOffset = ($content.Substring(0, $templateMatch.Groups[1].Index) -split "\r?\n").Count - 1
            $tplResult = Test-HtmlSyntax -content $templateMatch.Groups[1].Value
            if (-not $tplResult.Ok) {
                return @{Ok=$false;Message="Vue <template>: $($tplResult.Message)";Line=$tplResult.Line + $templateLineOffset}
            }
        }
        $scriptMatch = [regex]::Match($content, '(?s)<script[^>]*>(.*?)</script>')
        if ($scriptMatch.Success) {
            $scriptLineOffset = ($content.Substring(0, $scriptMatch.Groups[1].Index) -split "\r?\n").Count - 1
            $isTs = $scriptMatch.Value -match 'lang\s*=\s*["'']ts["'']'
            $scrResult = Test-StructuralSyntax -content $scriptMatch.Groups[1].Value -lang $(if ($isTs) { 'ts' } else { 'js' })
            if (-not $scrResult.Ok) {
                return @{Ok=$false;Message="Vue <script>: $($scrResult.Message)";Line=$scrResult.Line + $scriptLineOffset}
            }
        }
        $styleMatch = [regex]::Match($content, '(?s)<style[^>]*>(.*?)</style>')
        if ($styleMatch.Success) {
            $styleLineOffset = ($content.Substring(0, $styleMatch.Groups[1].Index) -split "\r?\n").Count - 1
            $stlResult = Test-CssSyntax -content $styleMatch.Groups[1].Value
            if (-not $stlResult.Ok) {
                return @{Ok=$false;Message="Vue <style>: $($stlResult.Message)";Line=$stlResult.Line + $styleLineOffset}
            }
        }
        # This whole branch only runs when vue-tsc (real semantic checker) was
        # unavailable or unusable — flag it so the caller knows "clean" here
        # means structurally clean only, not semantically reviewed.
        return @{Ok=$true;Message="";Line=0;Fallback=$true}
    }

    # ── BATCH/CMD.EXE STRUCTURAL VALIDATOR — narrow by design ───────────────
    # A bare 'script:' YAML step runs Bash on Linux/macOS but cmd.exe (batch
    # syntax) on Windows agents (confirmed via Microsoft's own docs). Batch is
    # a genuinely different, notoriously tricky micro-language — multi-phase
    # parsing, caret (^) escaping whose rules change under delayed expansion,
    # %var% vs !var! expansion timing. Rather than attempt all of that and
    # risk false positives, this checks ONLY what's safely structural:
    #   • Parenthesis balance — confirmed via research to be the ONE real
    #     structural delimiter in cmd.exe, used for IF/FOR code blocks (with
    #     a documented 256-level nesting cap before cmd.exe itself errors).
    #     Batch has NO brace ({}) syntax and NO bash-style $(/${ at all, so
    #     unlike Test-StructuralSyntax or the bash repair functions, only
    #     parens are tracked here — tracking braces or $-prefixed sequences
    #     would be solving a problem batch doesn't have.
    #   • Unterminated double-quoted strings, using batch's own ""-doubling
    #     escape convention (confirmed via research — NOT backslash like bash,
    #     and NOT single-quote-based at all; batch has no single-quote string
    #     concept).
    #   • '::' double-colon comment lines (a common batch REM-comment idiom)
    #     are skipped so a stray ( or " inside a comment is never miscounted.
    # Deliberately does NOT track caret escaping or delayed-expansion — both
    # are real but their correct handling depends on parsing context this
    # validator doesn't have, and a wrong guess here would be worse than no
    # check at all.
    function Test-BatchSyntax {
        param([string]$content)
        $parenDepth = 0
        $inDouble = $false
        $lineNum = 1
        $parenOpenLine = 0
        $atLineStart = $true

        $i = 0
        while ($i -lt $content.Length) {
            $c = $content[$i]
            $nc = if ($i + 1 -lt $content.Length) { $content[$i + 1] } else { '' }

            if ($c -eq "`n") { $lineNum++; $atLineStart = $true; $i++; continue }

            if ($inDouble) {
                if ($c -eq '"' -and $nc -eq '"') { $i += 2; continue }   # "" escape -- batch's real convention
                if ($c -eq '"') { $inDouble = $false }
                $atLineStart = $false; $i++; continue
            }

            # '::' double-colon comment — only recognized as the first token on
            # a line (the common batch REM-comment idiom); skip to end of line.
            if ($atLineStart -and $c -eq ':' -and $nc -eq ':') {
                $nl = $content.IndexOf("`n", $i)
                $i = if ($nl -ge 0) { $nl } else { $content.Length }
                continue
            }

            if ($c -ne ' ' -and $c -ne "`t") { $atLineStart = $false }

            if ($c -eq '"') { $inDouble = $true; $i++; continue }
            if ($c -eq '(') {
                if ($parenDepth -eq 0) { $parenOpenLine = $lineNum }
                $parenDepth++; $i++; continue
            }
            if ($c -eq ')') {
                $parenDepth--
                if ($parenDepth -lt 0) {
                    return @{Ok=$false;Message="Batch: unmatched closing ')' on line $lineNum";Line=$lineNum}
                }
                $i++; continue
            }
            $i++
        }

        if ($inDouble) {
            return @{Ok=$false;Message="Batch: unterminated double-quoted string — never closed before end of file";Line=$lineNum}
        }
        if ($parenDepth -ne 0) {
            return @{Ok=$false;Message="Batch: $parenDepth parenthesis/parentheses opened around line $parenOpenLine (likely an IF/FOR block) never closed";Line=$parenOpenLine}
        }
        return @{Ok=$true;Message="";Line=0}
    }

    # ── BUILD-TOOL ERROR EXTRACTOR ────────────────────────────────────────
    # Parses build log output from every major build tool to extract precise
    # file path + line number. This is MUCH more accurate than the
    # general log regex scan because each build tool's format is specific.
    # Used as Tier 0 — runs first, before the generic regex scan.
    # Covers: Maven, Gradle (Java+Kotlin), MSBuild (.NET), Go, TypeScript/tsc,
    # Python, Rust/Cargo, Swift, PHP, npm, Ruby, Bash, Terraform, Dockerfile, Groovy.
    function Extract-BuildErrors {
        param([string]$logText)
        $found = [System.Collections.Generic.List[object]]::new()
        $patterns = @(
            # Maven: [ERROR] /path/File.java:[42,10] error:
            [PSCustomObject]@{ Tool='Maven/Java';     Regex='\[ERROR\]\s+([^\s\[]+\.java):\[(\d+)';            FG=1; LG=2 },
            # Gradle Kotlin: e: file:///path/File.kt:42:10:
            [PSCustomObject]@{ Tool='Gradle/Kotlin';  Regex='e:\s+(?:file:///)?([^\s:]+\.kts?):(\d+)';         FG=1; LG=2 },
            # Gradle Java:  path/File.java:42: error:
            [PSCustomObject]@{ Tool='Gradle/Java';    Regex='([^\s:"]+\.java):(\d+):\s+error:';                 FG=1; LG=2 },
            # MSBuild C#:  path\File.cs(42,5): error CS...:
            [PSCustomObject]@{ Tool='MSBuild/C#';     Regex='([^\s"]+\.(?:cs|vb|fs))\((\d+),\d+\):\s+error';   FG=1; LG=2 },
            # Go:  ./path/file.go:42:3: undefined:
            [PSCustomObject]@{ Tool='Go';              Regex='(\.?/?[^\s:]+\.go):(\d+):\d+:';                   FG=1; LG=2 },
            # TypeScript tsc:  src/File.tsx(42,10): error TS...:
            [PSCustomObject]@{ Tool='TypeScript';     Regex='([^\s\(]+\.tsx?)\((\d+),\d+\):\s+error TS';        FG=1; LG=2 },
            # Python:  File "path/file.py", line 42
            [PSCustomObject]@{ Tool='Python';         Regex='File "([^"]+\.py)", line (\d+)';                   FG=1; LG=2 },
            # Rust/Cargo:  --> src/main.rs:23:15
            [PSCustomObject]@{ Tool='Rust/Cargo';     Regex='-->\s+([^\s:]+\.rs):(\d+):\d+';                    FG=1; LG=2 },
            # Swift:  /path/File.swift:42:10: error:
            [PSCustomObject]@{ Tool='Swift';          Regex='(/[^\s:]+\.swift):(\d+):\d+:\s+error:';            FG=1; LG=2 },
            # PHP:  Parse error: ... in /path/file.php on line 42
            [PSCustomObject]@{ Tool='PHP';            Regex='(?:Parse|Fatal) error.+?in\s+([^\s]+\.php) on line (\d+)'; FG=1; LG=2 },
            # Ruby:  path/file.rb:42: syntax error
            [PSCustomObject]@{ Tool='Ruby';           Regex='([^\s:]+\.rb):(\d+):\s+syntax error';              FG=1; LG=2 },
            # Bash: /path/script.sh: line 42:
            [PSCustomObject]@{ Tool='Bash';           Regex='(/[^\s:]+\.sh):\s*line\s*(\d+):';                  FG=1; LG=2 },
            # Terraform: Error on main.tf line 42:
            [PSCustomObject]@{ Tool='Terraform';      Regex='Error on ([^\s:]+\.tf) line (\d+):';               FG=1; LG=2 },
            # Groovy:  File.groovy: 42: unexpected token
            [PSCustomObject]@{ Tool='Groovy';         Regex='([^\s:]+\.groovy):\s*(\d+):\s+';                   FG=1; LG=2 },
            # hadolint Dockerfile: Dockerfile:42 DL...
            [PSCustomObject]@{ Tool='Dockerfile';     Regex='(Dockerfile):(\d+)\s+DL';                          FG=1; LG=2 }
        )
        $seen = [System.Collections.Generic.HashSet[string]]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($pat in $patterns) {
            foreach ($m in ([regex]::Matches($logText, $pat.Regex))) {
                $fp = $m.Groups[$pat.FG].Value.TrimStart('/\').Replace('\','/')
                [int]$ln = 0; [int]::TryParse($m.Groups[$pat.LG].Value, [ref]$ln) | Out-Null
                if (-not [string]::IsNullOrEmpty($fp) -and $ln -gt 0 -and $seen.Add("$fp`:$ln")) {
                    $found.Add([PSCustomObject]@{ File=$fp; Line=$ln; Tool=$pat.Tool })
                }
            }
        }
        return $found
    }

    # ── IMPORT-ERROR EXTRACTOR ────────────────────────────────────────────
    # Detects "missing import" errors from build logs that bypass syntax
    # validation — a file with a missing import has VALID syntax (python3
    # -m py_compile passes, node --check passes) but the build fails at
    # runtime/compilation with "ModuleNotFoundError", "Unresolved reference", etc.
    # Returns a hashtable of { filePath → @{Message; Symbol; Line} } so the
    # per-file loop can inject a synthetic error even when Get-SyntaxError
    # returns Ok=$true.
    function Get-ImportErrorMap {
        param([string]$logText)
        $map = @{}

        $importPatterns = @(
            # Python: ModuleNotFoundError / ImportError / NameError
            [PSCustomObject]@{
                Lang = 'python'
                FileRx = 'File "([^"]+\.py)", line \d+'
                ErrRx  = '(?:ModuleNotFoundError|ImportError|NameError):\s*(.+)'
                FileG  = 1; ErrG = 1
            },
            # Python alternative: cannot import name 'X' from 'Y'
            [PSCustomObject]@{
                Lang = 'python'
                FileRx = 'File "([^"]+\.py)"'
                ErrRx  = 'cannot import name [''"](\w+)[''"] from [''"]([^''\"]+)[''"]'
                FileG  = 1; ErrG = 0  # ErrG=0 means use full match
            },
            # JavaScript/TypeScript: Cannot find module 'X'
            # Extended to .jsx/.js: tsc produces this exact (line,col) diagnostic
            # format regardless of which of .ts/.tsx/.jsx/.js it's checking (it's
            # tsc's own output format, not specific to the TypeScript extensions) —
            # the .jsx branch in Get-SyntaxError now runs through tsc too, so this
            # needed to widen to match or it would silently miss tsc's "Cannot find
            # module" errors against .jsx files specifically.
            [PSCustomObject]@{
                Lang = 'javascript'
                FileRx = '([^\s\(]+\.(?:tsx?|jsx?))\(\d+,\d+\)'
                ErrRx  = "Cannot find module '([^']+)'"
                FileG  = 1; ErrG = 1
            },
            # TypeScript: 'X' is not defined / Cannot find name 'X'
            # Same widening as above, same reasoning.
            [PSCustomObject]@{
                Lang = 'typescript'
                FileRx = '([^\s\(]+\.(?:tsx?|jsx?))\(\d+,\d+\)'
                ErrRx  = "Cannot find name '(\w+)'"
                FileG  = 1; ErrG = 1
            },
            # Kotlin: Unresolved reference: X
            [PSCustomObject]@{
                Lang = 'kotlin'
                FileRx = 'e:\s+(?:file:///)?([^\s:]+\.kts?)'
                ErrRx  = 'Unresolved reference:\s*(\w+)'
                FileG  = 1; ErrG = 1
            },
            # Java: cannot find symbol / package X does not exist
            [PSCustomObject]@{
                Lang = 'java'
                FileRx = '([^\s:"]+\.java):\d+:'
                ErrRx  = '(?:cannot find symbol|package ([\w\.]+) does not exist)'
                FileG  = 1; ErrG = 1
            },
            # Swift: use of unresolved identifier 'X'
            [PSCustomObject]@{
                Lang = 'swift'
                FileRx = '(/[^\s:]+\.swift):\d+'
                ErrRx  = "use of unresolved identifier '(\w+)'"
                FileG  = 1; ErrG = 1
            },
            # Go: undefined: X
            [PSCustomObject]@{
                Lang = 'go'
                FileRx = '(\.?/?[^\s:]+\.go):\d+'
                ErrRx  = 'undefined:\s*(\w+)'
                FileG  = 1; ErrG = 1
            },
            # Ruby: NameError: uninitialized constant X
            [PSCustomObject]@{
                Lang = 'ruby'
                FileRx = '([^\s:]+\.rb):\d+'
                ErrRx  = 'NameError: uninitialized constant (\w+)'
                FileG  = 1; ErrG = 1
            },
            # PHP: Class 'X' not found / Call to undefined function X
            [PSCustomObject]@{
                Lang = 'php'
                FileRx = 'in ([^\s]+\.php)'
                ErrRx  = "(?:Class '(\w+)' not found|Call to undefined function (\w+))"
                FileG  = 1; ErrG = 1
            },
            # C#: CS0246 The type or namespace name 'X' could not be found
            [PSCustomObject]@{
                Lang = 'csharp'
                FileRx = '([^\s"]+\.cs)\(\d+'
                ErrRx  = "CS0246.+?'(\w+)' could not be found"
                FileG  = 1; ErrG = 1
            }
        )

        foreach ($pat in $importPatterns) {
            $fileMatches = [regex]::Matches($logText, $pat.FileRx)
            $errMatches  = [regex]::Matches($logText, $pat.ErrRx)
            if ($fileMatches.Count -eq 0 -or $errMatches.Count -eq 0) { continue }
            $fp = $fileMatches[0].Groups[$pat.FileG].Value.TrimStart('/\').Replace('\','/')
            $symbol = if ($pat.ErrG -eq 0) { $errMatches[0].Value } else { $errMatches[0].Groups[$pat.ErrG].Value }
            if ([string]::IsNullOrEmpty($fp) -or [string]::IsNullOrEmpty($symbol)) { continue }
            if (-not $map.ContainsKey($fp)) {
                $msg = "Missing import: '$symbol' — $($pat.Lang) build log reports '$($errMatches[0].Value)'. Add the correct import statement for '$symbol' at the top of this file."
                $map[$fp] = @{ Message = $msg; Symbol = $symbol; Lang = $pat.Lang }
                Write-Host "[ImportMap] $($pat.Lang) missing '$symbol' in $fp"
            }
        }
        return $map
    }

    # ── BUNDLER ERROR DETECTOR ────────────────────────────────────────────
    # Ruby bundler errors (Gem::LoadError, "X is not part of the bundle",
    # "Could not find gem 'X'") are NOT associated with any source file path
    # in the build log — they happen at fastlane/bundler startup. So they
    # never populate candidatePaths through Tier 0-3 and are never picked up
    # by Get-ImportErrorMap (which requires a file path match).
    # This function detects them directly and produces Gemfile fixes.
    function Get-BundlerFixes {
        param([string]$logText)
        $fixes = [System.Collections.Generic.List[object]]::new()

        # Detect missing gem names from bundler error messages.
        $patterns = @(
            '([a-zA-Z][\w_-]+)\s+is not part of the bundle',
            "Could not find gem '([^']+)'",
            'Gem::LoadError[^:]*:\s*([a-zA-Z][\w_-]+)\s+is not',
            'Add it to your Gemfile:\s*gem\s+[''"]?([^''",\s]+)[''"]?',
            "cannot load such file -- ([a-zA-Z][\w/_-]+)",
            'LoadError: cannot load such file -- ([a-zA-Z][\w/_-]+)',
            "require: cannot load such file -- ([a-zA-Z][\w/_-]+)",
            'bundler: failed to load command.*because it requires a gem that is not available:\s*([a-zA-Z][\w_-]+)',
            "Your bundle is locked to ([a-zA-Z][\w_-]+)",
            "Gem ([a-zA-Z][\w_-]+) not found",
            "Could not find ([a-zA-Z][\w_-]+) in any of the sources",
            # ── "command not found" — gem was removed from Gemfile ──────────
            # When a gem (fastlane, cocoapods, etc.) is removed from the Gemfile,
            # bundle install succeeds but later commands fail at runtime because
            # the binary is no longer in the bundle.
            'bundler: command not found: ([a-zA-Z][\w_-]+)',
            'sh: \d+: ([a-zA-Z][\w_-]+): not found',
            "command not found: ([a-zA-Z][\w_-]+)",
            'bash: ([a-zA-Z][\w_-]+): command not found',
            # Fastlane-specific: missing from Gemfile entirely
            "Could not find gem '(fastlane[^']*)'",
            'The (fastlane[\w_-]*) gem is required',
            "Please add (cocoapods[^']*) to your Gemfile"
        )

        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($pat in $patterns) {
            foreach ($m in [regex]::Matches($logText, $pat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $pkg = $m.Groups[1].Value.Trim()
                if (-not [string]::IsNullOrEmpty($pkg) -and -not $missing.Contains($pkg)) {
                    $missing.Add($pkg)
                }
            }
        }
        if ($missing.Count -eq 0) { return $fixes }

        # ── Binary name → gem name mapping ───────────────────────────────────
        # Some gems install under a different binary name than the gem name.
        # "command not found: pod" means the 'cocoapods' gem is missing — NOT a 'pod' gem.
        $binaryToGem = @{
            'pod'       = 'cocoapods'
            'fastlane'  = 'fastlane'
            'bundle'    = 'bundler'
            'xcpretty'  = 'xcpretty'
            'slather'   = 'slather'
            'danger'    = 'danger'
            'synx'      = 'synx'
            'brew'      = $null   # homebrew — not a gem, skip
            'xcodebuild'= $null   # Xcode — not a gem, skip
            'swift'     = $null   # Swift compiler — not a gem, skip
            'ruby'      = $null   # skip
            'sh'        = $null   # skip
            'bash'      = $null   # skip
        }
        $resolvedMissing = [System.Collections.Generic.List[string]]::new()
        foreach ($pkg in $missing) {
            if ($binaryToGem.ContainsKey($pkg)) {
                $resolved = $binaryToGem[$pkg]
                if ($null -ne $resolved -and -not $resolvedMissing.Contains($resolved)) {
                    $resolvedMissing.Add($resolved)
                    Write-Host "[BundlerFix] Mapped binary '$pkg' → gem '$resolved'"
                }
            } else {
                if (-not $resolvedMissing.Contains($pkg)) { $resolvedMissing.Add($pkg) }
            }
        }
        $missing = $resolvedMissing
        Write-Host "[BundlerFix] Detected missing gem(s): $($missing -join ', ')"

        # ── GEMFILE DISCOVERY ────────────────────────────────────────────────
        $repoRoot = $env:BUILD_SOURCESDIRECTORY
        $gemfileFullPath = $null

        Write-Host "[BundlerFix] Searching for Gemfile recursively under $repoRoot ..."
        $found = Get-ChildItem -Path $repoRoot -Filter 'Gemfile' -Recurse -Depth 8 -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|vendor|\.gems|Pods|Carthage)[\\/]' } |
                 Select-Object -First 1
        if ($null -ne $found) { $gemfileFullPath = $found.FullName }

        if ($null -eq $gemfileFullPath) {
            Write-Host "[BundlerFix] ⚠️ No Gemfile found anywhere in repo — add gems manually."
            return $fixes
        }

        $gemfileRelPath = $gemfileFullPath.Replace($repoRoot, '').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
        Write-Host "[BundlerFix] Gemfile relative path: $gemfileRelPath"

        $depContent = Get-Content $gemfileFullPath -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($depContent)) {
            Write-Host "[BundlerFix] ⚠️ Could not read Gemfile content from disk."
            return $fixes
        }
        $depLines = $depContent -split "`r?`n"

        # ── GEMFILE.LOCK VERSION LOOKUP ──────────────────────────────────────
        # When a gem is removed from Gemfile and re-added, preserve the exact
        # version that was working (from Gemfile.lock) to avoid introducing
        # version conflicts or pulling an incompatible release.
        # Gemfile.lock format:  "    gemname (1.2.3)"  (4-space indent)
        $lockVersions = @{}
        $lockPath = Join-Path (Split-Path $gemfileFullPath) 'Gemfile.lock'
        if (Test-Path $lockPath) {
            $lockContent = Get-Content $lockPath -Raw -ErrorAction SilentlyContinue
            foreach ($lm in [regex]::Matches($lockContent, '^\s{4}([\w_-]+)\s+\(([^)]+)\)', [System.Text.RegularExpressions.RegexOptions]::Multiline)) {
                $lockVersions[$lm.Groups[1].Value] = $lm.Groups[2].Value
            }
            Write-Host "[BundlerFix] Read $($lockVersions.Count) version(s) from Gemfile.lock"
        }

        # ── KNOWN VERSION CONSTRAINTS for common gems ──────────────────────
        foreach ($pkg in $missing) {
            if ($pkg.Length -lt 3) { Write-Host "  ⚠️ Skipping '$pkg' — too short to be a gem name"; continue }
            if ($pkg -match '[\[\]()\\^$.*+?{}|]') { Write-Host "  ⚠️ Skipping '$pkg' — contains regex metacharacters"; continue }
            if ($pkg -match '^(File|Path|Error|Class|Type|Name|Load|Gem|Add|Run|Use|Get|Set|New|Its|Not|The|And|For|You|Was|Can|Did|Has|sh|bash|bundle|ruby|gem)$') {
                Write-Host "  ⚠️ Skipping '$pkg' — common word or shell command, not a gem name"; continue
            }

            if ($depContent -match "gem\s+['""]$([regex]::Escape($pkg))['""]") {
                Write-Host "  ℹ️ '$pkg' already in Gemfile — skipping"
                continue
            }

            # ── Determine version string ────────────────────────────────────
            # Priority: 1) Gemfile.lock exact version (the version that was working)
            #            2) RubyGems API latest stable release (dynamic — no hardcoding)
            #            3) Bare gem name (fallback when registry is unreachable)
            $versionStr = ''
            if ($lockVersions.ContainsKey($pkg)) {
                $lockVer = $lockVersions[$pkg]
                if ($lockVer -match '^(\d+\.\d+)') { $versionStr = ", '~> $($matches[1])'" }
                elseif ($lockVer -match '^\d+$')   { $versionStr = ", '~> $lockVer'" }
                Write-Host "  ℹ️ Using Gemfile.lock version for '$pkg': $lockVer → $versionStr"
            } else {
                # No lock file entry — query RubyGems for the latest stable release
                $apiVer = Get-LatestGemVersion -gemName $pkg
                if ($apiVer) { $versionStr = ", '$apiVer'" }
            }

            Write-Host "  ✅ Queuing Gemfile fix: add gem '$pkg'$versionStr"
            $newLine    = "gem '$pkg'$versionStr"
            $newContent = ($depLines + @($newLine)) -join "`n"
            $lastLine   = if ($depLines.Count -gt 0) { $depLines[-1] } else { '' }
            $fixes.Add([PSCustomObject]@{
                file_path    = $gemfileRelPath
                line_number  = $depLines.Count + 1
                title        = "Add missing gem '$pkg'$versionStr to Gemfile"
                old_code     = $lastLine
                new_code     = $lastLine + "`n$newLine"
                confidence   = 0.95
                _fullContent = $newContent
            })
        }
        return $fixes
    }

    # ── FASTLANE PLUGIN FIXES ─────────────────────────────────────────────────
    # Detects 'Could not find action, lane or variable X' errors — a completely
    # different error class from bundler errors. Fastlane actions that come from
    # plugins (e.g. firebase_app_distribution) are NOT in the bundler error log.
    # They fail at runtime when Fastlane tries to call an action it can't find.
    # This function maps known Fastlane action names → their plugin gem names
    # and adds the missing gem to the Gemfile (or Pluginfile if present).
    # No AI call needed — deterministic knowledge base → zero hallucination.
    function Get-FastlanePluginFixes {
        param([string]$logText)
        $fixes = [System.Collections.Generic.List[object]]::new()

        # Detect all 'Could not find action, lane or variable' errors
        $missingActions = [System.Collections.Generic.List[string]]::new()
        foreach ($m in [regex]::Matches($logText, "Could not find action, lane or variable '([^']+)'")) {
            $action = $m.Groups[1].Value.Trim()
            if (-not $missingActions.Contains($action)) { $missingActions.Add($action) }
        }
        # Also catch: "undefined method 'X'" which can indicate a missing plugin
        foreach ($m in [regex]::Matches($logText, "undefined method '([a-z][a-z0-9_]+)'.*fastlane", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $action = $m.Groups[1].Value.Trim()
            if (-not $missingActions.Contains($action)) { $missingActions.Add($action) }
        }

        if ($missingActions.Count -eq 0) { return $fixes }
        Write-Host "[PluginFix] Missing Fastlane action(s): $($missingActions -join ', ')"

        # ── Knowledge base: Fastlane action name → plugin gem ─────────────────
        # Covers the 40+ most common Fastlane plugins. For unlisted actions the
        # convention 'fastlane-plugin-{action}' is tried as a fallback.
        $pluginMap = @{
            # Firebase App Distribution
            'firebase_app_distribution'               = 'fastlane-plugin-firebase_app_distribution'
            'upload_to_firebase_app_distribution'     = 'fastlane-plugin-firebase_app_distribution'
            # App Center (replaces HockeyApp)
            'appcenter_upload'                        = 'fastlane-plugin-appcenter'
            'appcenter_fetch_devices'                 = 'fastlane-plugin-appcenter'
            # HockeyApp (legacy)
            'hockey'                                  = 'fastlane-plugin-hockey'
            # TestFairy
            'testfairy'                               = 'fastlane-plugin-testfairy'
            'upload_to_testfairy'                     = 'fastlane-plugin-testfairy'
            # BrowserStack
            'upload_to_browserstack'                  = 'fastlane-plugin-browserstack'
            'browserstack_local'                      = 'fastlane-plugin-browserstack'
            # Dynatrace
            'upload_symbols_to_dynatrace'             = 'fastlane-plugin-dynatrace'
            'dynatrace_process_symbols'               = 'fastlane-plugin-dynatrace'
            # Versioning (plist / xcconfig)
            'increment_version_number_in_plist'       = 'fastlane-plugin-versioning'
            'increment_build_number_in_plist'         = 'fastlane-plugin-versioning'
            'get_version_number_from_plist'           = 'fastlane-plugin-versioning'
            'set_version_number_in_plist'             = 'fastlane-plugin-versioning'
            'get_build_number_from_plist'             = 'fastlane-plugin-versioning'
            'increment_version_number_in_xcconfig'    = 'fastlane-plugin-versioning'
            # Badge / Shield icons
            'badge'                                   = 'fastlane-plugin-badge'
            'shield'                                  = 'fastlane-plugin-badge'
            'add_badge'                               = 'fastlane-plugin-badge'
            # Changelog management
            'read_changelog'                          = 'fastlane-plugin-changelog'
            'stamp_changelog'                         = 'fastlane-plugin-changelog'
            'update_changelog'                        = 'fastlane-plugin-changelog'
            'write_changelog'                         = 'fastlane-plugin-changelog'
            # Semantic release
            'conventional_changelog'                  = 'fastlane-plugin-semantic_release'
            'analyze_commits'                         = 'fastlane-plugin-semantic_release'
            'next_build_number'                       = 'fastlane-plugin-semantic_release'
            # Emerge (binary size)
            'emerge_upload'                           = 'fastlane-plugin-emerge'
            # AppLivery
            'applivery'                               = 'fastlane-plugin-applivery'
            # Amazon S3
            'upload_to_s3'                            = 'fastlane-plugin-s3'
            's3'                                      = 'fastlane-plugin-s3'
            # Jira
            'jira_transitions'                        = 'fastlane-plugin-jira_transitions'
            'create_jira_version'                     = 'fastlane-plugin-jira'
            'close_jira_milestone'                    = 'fastlane-plugin-jira'
            # Instabug
            'instabug'                                = 'fastlane-plugin-instabug'
            # Branch.io deep links
            'add_url_scheme'                          = 'fastlane-plugin-branch'
            # Flutter
            'flutter'                                 = 'fastlane-plugin-flutter'
            # Waldo
            'waldo_upload'                            = 'fastlane-plugin-waldo'
            # Sonar
            'sonar'                                   = 'fastlane-plugin-sonar'
            # OneSignal
            'onesignal'                               = 'fastlane-plugin-onesignal'
            # Android versioning
            'android_version'                         = 'fastlane-plugin-android_version'
            'get_android_version'                     = 'fastlane-plugin-android_version'
            'increment_android_version'               = 'fastlane-plugin-android_version'
            # Google Chat
            'google_chat'                             = 'fastlane-plugin-google_chat'
            # MS Teams notification
            'ms_teams'                                = 'fastlane-plugin-ms_teams'
            # Bitrise artifact
            'bitrise_artifact'                        = 'fastlane-plugin-bitrise_artifact'
            # Sentry — crash reporting + dsym upload
            'sentry_upload_dsym'                      = 'fastlane-plugin-sentry'
            'sentry_upload_file'                      = 'fastlane-plugin-sentry'
            'sentry_create_release'                   = 'fastlane-plugin-sentry'
            # Firebase Crashlytics (legacy + new)
            'crashlytics'                             = 'fastlane-plugin-crashlytics'
            'upload_symbols_to_crashlytics'           = 'fastlane-plugin-crashlytics'
            'firebase_crashlytics'                    = 'fastlane-plugin-firebase_app_distribution'
            # Xcode version management
            'xcversion'                               = 'fastlane-plugin-xcode_install'
            'xcode_install'                           = 'fastlane-plugin-xcode_install'
            'resolve_xcode_version'                   = 'fastlane-plugin-xcode_install'
            # Android version code
            'increment_version_code'                  = 'fastlane-plugin-increment_version_code'
            'get_version_code'                        = 'fastlane-plugin-android_version'
            # Localization / translation
            'poeditor_export'                         = 'fastlane-plugin-poeditor'
            'lokalise_download'                       = 'fastlane-plugin-lokalise'
            'lokalise_upload'                         = 'fastlane-plugin-lokalise'
            'phrase_download'                         = 'fastlane-plugin-phrase'
            # Code signing helpers
            'resign'                                  = 'fastlane-plugin-resign'
            'update_code_signing_settings'            = 'fastlane-plugin-update_code_signing_settings'
            # Xcodegen
            'xcodegen'                                = 'fastlane-plugin-xcodegen'
            # ── Version management ─────────────────────────────────────
            'increment_version_number'                = 'fastlane-plugin-increment_version_number'
            'android_manifest'                        = 'fastlane-plugin-android_manifest'
            'commit_android_version_bump'             = 'fastlane-plugin-commit_android_version_bump'
            'flutter_version'                         = 'fastlane-plugin-flutter_version'
            # ── Distribution / stores ───────────────────────────────────
            'huawei_appgallery_connect'               = 'fastlane-plugin-huawei_appgallery_connect'
            'samsung_galaxy_store'                    = 'fastlane-plugin-samsung_galaxy_store'
            'clean_testflight_testers'                = 'fastlane-plugin-clean_testflight_testers'
            'apprepo'                                 = 'fastlane-plugin-apprepo'
            # ── Code quality / testing ──────────────────────────────────
            'test_center'                             = 'fastlane-plugin-test_center'
            'xcconfig_actions'                        = 'fastlane-plugin-xcconfig_actions'
            # NOTE: 'xcversion' key already registered above for fastlane-plugin-xcode_install
            #       (both plugins share the same action name — xcode_install wins as it is more widely used)
            'android_emulator'                        = 'fastlane-plugin-android_emulator'
            # ── Framework / dependency tools ────────────────────────────
            'cryptex'                                 = 'fastlane-plugin-cryptex'
            'match_keychain'                          = 'fastlane-plugin-match_keychain'
            'cocoapods_acknowledgements'              = 'fastlane-plugin-cocoapods_acknowledgements'
            # ── Cross-platform / hybrid ─────────────────────────────────
            'cordova'                                 = 'fastlane-plugin-cordova'
            'ionic'                                   = 'fastlane-plugin-ionic'
            'react_native_release'                    = 'fastlane-plugin-react_native_release'
            # ── Integrations / notifications ─────────────────────────────
            'github_action'                           = 'fastlane-plugin-github_action'
            'cerberus'                                = 'fastlane-plugin-cerberus'
            'appsee'                                  = 'fastlane-plugin-appsee'
            'apptweak'                                = 'fastlane-plugin-apptweak'
            # Jira (Atlassian)
            'jira_comment'                            = 'fastlane-plugin-jira'
            'release_jira_version'                    = 'fastlane-plugin-jira'
            # Slack (custom plugin variant)
            'slack_message'                           = 'fastlane-plugin-slack_bot'
            # DataDog
            'datadog_dif_upload'                      = 'fastlane-plugin-datadog'
            # Appetize.io
            'appetize_deploy'                         = 'fastlane-plugin-appetize'
            # Diawi (OTA distribution)
            'diawi'                                   = 'fastlane-plugin-diawi'
            # GitLab artifacts
            'gitlab_upload_file'                      = 'fastlane-plugin-gitlab'
            # Firebase Test Lab — cloud device testing
            'run_tests_firebase_testlab'              = 'fastlane-plugin-firebase_test_lab'
            'firebase_test_lab'                       = 'fastlane-plugin-firebase_test_lab'
            # DeployGate — OTA distribution
            'deploygate'                              = 'fastlane-plugin-deploygate'
            'upload_to_deploygate'                    = 'fastlane-plugin-deploygate'
            # Trainer — convert xcresult to JUnit XML
            'trainer'                                 = 'fastlane-plugin-trainer'
            'xcresult_to_junit'                       = 'fastlane-plugin-xcresult_to_junit'
            # Update Info.plist values
            'update_info_plist_value'                 = 'fastlane-plugin-update_plist'
            'update_plist'                            = 'fastlane-plugin-update_plist'
            'set_info_plist_value'                    = 'fastlane-plugin-update_plist'
            # AWS S3 (Fastlane-specific plugin, distinct from supply/sigh)
            'aws_s3'                                  = 'fastlane-plugin-aws_s3'
            # New Relic — mobile monitoring
            'upload_symbols_to_new_relic'             = 'fastlane-plugin-new_relic'
            'new_relic_upload_dsym'                   = 'fastlane-plugin-new_relic'
            # Rocket.Chat notifications
            'rocket_chat'                             = 'fastlane-plugin-rocket_chat'
            # App Store review time tracker
            'check_app_store_review_time'             = 'fastlane-plugin-review_time'
            # Danger — code review automation
            'danger'                                  = 'danger'
            # BundleGen (bundle generation tools)
            'bundletool'                              = 'fastlane-plugin-bundletool'
            # Airship (Urban Airship) push notifications
            'airship'                                 = 'fastlane-plugin-airship'
            # Testmunk device cloud
            'testmunk'                                = 'fastlane-plugin-testmunk'
        }

        $repoRoot = $env:BUILD_SOURCESDIRECTORY

        # ── Find Pluginfile first, fall back to Gemfile ───────────────────────
        # Fastlane recommends plugins in fastlane/Pluginfile, not the main Gemfile.
        # If Pluginfile exists → use it. If not → use Gemfile.
        $targetFilePath = $null; $targetRelPath = ""; $isPluginfile = $false

        $pluginFile = Get-ChildItem -Path $repoRoot -Filter 'Pluginfile' -Recurse -Depth 8 -EA SilentlyContinue |
                      Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|vendor)[\\/]' } |
                      Select-Object -First 1
        if ($null -ne $pluginFile) {
            $targetFilePath = $pluginFile.FullName
            $targetRelPath  = $pluginFile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
            $isPluginfile   = $true
            Write-Host "[PluginFix] Target: Pluginfile at $targetRelPath"
        } else {
            $gemFile = Get-ChildItem -Path $repoRoot -Filter 'Gemfile' -Recurse -Depth 8 -EA SilentlyContinue |
                       Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|vendor|\.gems|Pods)[\\/]' } |
                       Select-Object -First 1
            if ($null -ne $gemFile) {
                $targetFilePath = $gemFile.FullName
                $targetRelPath  = $gemFile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
                Write-Host "[PluginFix] No Pluginfile found — using Gemfile at $targetRelPath"
            }
        }

        if ($null -eq $targetFilePath) {
            Write-Host "[PluginFix] ⚠️ No Pluginfile or Gemfile found — cannot auto-add plugin."
            return $fixes
        }

        $fileContent = Get-Content $targetFilePath -Raw -EA SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($fileContent)) { return $fixes }
        $fileLines = $fileContent -split "`r?`n"

        foreach ($action in $missingActions) {
            # Resolve gem name from knowledge base, or use convention fallback
            $gemName = if ($pluginMap.ContainsKey($action)) {
                $pluginMap[$action]
            } else {
                # Convention: most Fastlane plugins are 'fastlane-plugin-<action>'
                $guessedGem = "fastlane-plugin-$($action -replace '_','-')"
                Write-Host "[PluginFix] '$action' not in knowledge base — guessing gem: $guessedGem"
                $guessedGem
            }

            # Skip if gem already present
            if ($fileContent -match [regex]::Escape($gemName)) {
                Write-Host "[PluginFix] '$gemName' already in $targetRelPath — skipping"
                continue
            }

            Write-Host "[PluginFix] ✅ Queuing fix: add gem '$gemName' to $targetRelPath"
            $newGemLine  = "gem '$gemName'"
            $newContent  = ($fileLines + @($newGemLine)) -join "`n"
            $lastLine    = if ($fileLines.Count -gt 0) { $fileLines[-1] } else { '' }

            $fixes.Add([PSCustomObject]@{
                file_path    = $targetRelPath
                line_number  = $fileLines.Count + 1
                title        = "Add missing Fastlane plugin: $gemName (required by '$action' action — 'Could not find action' error)"
                old_code     = $lastLine
                new_code     = $lastLine + "`n$newGemLine"
                confidence   = 0.98
                _fullContent = $newContent
            })
        }
        return $fixes
    }

    # ── REGISTRY VERSION LOOKUP HELPERS ─────────────────────────────────────────
    # Query public package registries at runtime to find the latest stable version.
    # Priority used by every fix function:
    #   1) Lock file (Gemfile.lock / package-lock.json / Podfile.lock / Pipfile.lock)
    #      → exact version that was working before — highest confidence
    #   2) Registry API (RubyGems / npm / PyPI / CocoaPods Trunk / Maven Central)
    #      → latest stable release — always up-to-date, zero hardcoding
    #   3) Bare package name (no version) — fallback when network is unreachable
    #
    # Results are cached in $script:registryVersionCache for the lifetime of this
    # triage run so the same gem/package is never queried twice.
    # All API calls use an 8-second timeout and fail silently on error.

    if ($null -eq $script:registryVersionCache) {
        $script:registryVersionCache = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
    }

    function Get-LatestGemVersion {
        param([string]$gemName)
        $key = "gem:$gemName"; $cached = $null
        if ($script:registryVersionCache.TryGetValue($key, [ref]$cached)) { return $cached }
        try {
            $r = Invoke-RestMethod -Uri "https://rubygems.org/api/v1/gems/$([uri]::EscapeDataString($gemName)).json" -TimeoutSec 8 -EA Stop
            if ($r.version -match '^(\d+\.\d+)') {
                $result = "~> $($matches[1])"
                [void]$script:registryVersionCache.TryAdd($key, $result)
                Write-Host "  [Registry] RubyGems: $gemName = $($r.version) → '$result'"
                return $result
            }
        } catch { Write-Host "  [Registry] RubyGems lookup skipped for '$gemName' (no network or not found)" }
        [void]$script:registryVersionCache.TryAdd($key, '')
        return ''
    }

    function Get-LatestNpmVersion {
        param([string]$packageName)
        $key = "npm:$packageName"; $cached = $null
        if ($script:registryVersionCache.TryGetValue($key, [ref]$cached)) { return $cached }
        try {
            $r = Invoke-RestMethod -Uri "https://registry.npmjs.org/$([uri]::EscapeDataString($packageName))/latest" -TimeoutSec 8 -EA Stop
            if ($r.version -match '^\d+\.\d+') {
                $result = "^$($r.version)"
                [void]$script:registryVersionCache.TryAdd($key, $result)
                Write-Host "  [Registry] npm: $packageName = $($r.version) → '$result'"
                return $result
            }
        } catch { Write-Host "  [Registry] npm lookup skipped for '$packageName' (no network or not found)" }
        [void]$script:registryVersionCache.TryAdd($key, 'latest')
        return 'latest'   # bare 'latest' only when registry is unreachable
    }

    function Get-LatestPipVersion {
        param([string]$packageName)
        $key = "pip:$packageName"; $cached = $null
        if ($script:registryVersionCache.TryGetValue($key, [ref]$cached)) { return $cached }
        try {
            $r = Invoke-RestMethod -Uri "https://pypi.org/pypi/$([uri]::EscapeDataString($packageName))/json" -TimeoutSec 8 -EA Stop
            if ($r.info.version -match '^\d+\.\d+') {
                $result = ">=$($r.info.version)"
                [void]$script:registryVersionCache.TryAdd($key, $result)
                Write-Host "  [Registry] PyPI: $packageName = $($r.info.version) → '$result'"
                return $result
            }
        } catch { Write-Host "  [Registry] PyPI lookup skipped for '$packageName' (no network or not found)" }
        [void]$script:registryVersionCache.TryAdd($key, '')
        return ''
    }

    function Get-LatestPodVersion {
        param([string]$podName)
        $key = "pod:$podName"; $cached = $null
        if ($script:registryVersionCache.TryGetValue($key, [ref]$cached)) { return $cached }
        try {
            $r = Invoke-RestMethod -Uri "https://trunk.cocoapods.org/api/v1/pods/$([uri]::EscapeDataString($podName))" -TimeoutSec 8 -EA Stop
            # versions array is sorted ascending — latest is last element
            $versions = if ($r.versions -is [array]) { $r.versions } else { @($r.versions) }
            $latestVer = ($versions | Select-Object -Last 1).name
            if ($latestVer -match '^(\d+\.\d+)') {
                $result = "~> $($matches[1])"
                [void]$script:registryVersionCache.TryAdd($key, $result)
                Write-Host "  [Registry] CocoaPods Trunk: $podName = $latestVer → '$result'"
                return $result
            }
        } catch { Write-Host "  [Registry] CocoaPods Trunk lookup skipped for '$podName' (no network or not found)" }
        [void]$script:registryVersionCache.TryAdd($key, '')
        return ''
    }

    function Get-LatestMavenVersion {
        param([string]$groupId, [string]$artifactId)
        $key = "maven:$groupId`:$artifactId"; $cached = $null
        if ($script:registryVersionCache.TryGetValue($key, [ref]$cached)) { return $cached }
        try {
            $q = "g:$([uri]::EscapeDataString($groupId))+AND+a:$([uri]::EscapeDataString($artifactId))"
            $r = Invoke-RestMethod -Uri "https://search.maven.org/solrsearch/select?q=$q&rows=1&wt=json" -TimeoutSec 8 -EA Stop
            $ver = $r.response.docs[0].latestVersion
            if ($ver -match '^\d+') {
                [void]$script:registryVersionCache.TryAdd($key, $ver)
                Write-Host "  [Registry] Maven Central: $groupId`:$artifactId = $ver"
                return $ver
            }
        } catch { Write-Host "  [Registry] Maven Central lookup skipped for '$groupId`:$artifactId' (no network or not found)" }
        [void]$script:registryVersionCache.TryAdd($key, '')
        return ''
    }

    # ════════════════════════════════════════════════════════════════════════════
    # BUILD PREFLIGHT AUDIT — 5-Category Static Analysis
    # Runs on EVERY failed build at Phase 0, before any error-pattern matching.
    # Inspects the repo + environment DIRECTLY without relying on what appears in
    # the build log — catches failures that happen in 1 second just as well as
    # failures that happen at the very end of a 45-minute build.
    #
    # Category 1: Dependencies    — Gemfile, Pluginfile, Fastfile references
    # Category 2: Code Signing    — Match config, credentials, cert/profile expiry
    # Category 3: Distribution   — Firebase, AppStore, Google Play, AppCenter
    # Category 4: Environment    — ADO macros not resolved, tool versions
    # Category 5: Config files   — Fastfile lanes, Matchfile, Gymfile, Appfile
    # ════════════════════════════════════════════════════════════════════════════

    # ── HELPER: generate MANUAL ACTION fix with step-by-step instructions ───────
    function New-ManualActionFix {
        param(
            [string]$Category,
            [string]$Title,
            [string]$Instructions,
            [string]$FilePath = 'PIPELINE_CONFIGURATION',
            [double]$Confidence = 0.90
        )
        return [PSCustomObject]@{
            file_path    = $FilePath
            line_number  = 0
            title        = "MANUAL ACTION [$Category]: $Title"
            old_code     = $null
            new_code     = $null
            confidence   = $Confidence
            _fullContent = $null
            instructions = $Instructions
        }
    }

    function Invoke-BuildPreflightAudit {
        param([string]$logText)
        $fixes = [System.Collections.Generic.List[object]]::new()
        $repoRoot = $env:BUILD_SOURCESDIRECTORY
        if ([string]::IsNullOrWhiteSpace($repoRoot)) { return $fixes }

        Write-Host "`n╔══════════════════════════════════════════════════╗"
        Write-Host   "║  BUILD PREFLIGHT AUDIT — 5-Category Check        ║"
        Write-Host   "╚══════════════════════════════════════════════════╝"

        # ──────────────────────────────────────────────────────────────────────
        # SHARED: Read key config files once — used across all categories
        # ──────────────────────────────────────────────────────────────────────
        $gemfile   = Get-ChildItem -Path $repoRoot -Filter 'Gemfile'   -Recurse -Depth 8 -EA SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](\.git|vendor|Pods|build)[\\/]' } | Select-Object -First 1
        $fastfile  = Get-ChildItem -Path $repoRoot -Filter 'Fastfile'  -Recurse -Depth 8 -EA SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|vendor)[\\/]' } | Select-Object -First 1
        $matchfile = Get-ChildItem -Path $repoRoot -Filter 'Matchfile' -Recurse -Depth 8 -EA SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } | Select-Object -First 1
        $gymfile   = Get-ChildItem -Path $repoRoot -Filter 'Gymfile'   -Recurse -Depth 8 -EA SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } | Select-Object -First 1
        $appfile   = Get-ChildItem -Path $repoRoot -Filter 'Appfile'   -Recurse -Depth 8 -EA SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } | Select-Object -First 1
        $podfile   = Get-ChildItem -Path $repoRoot -Filter 'Podfile'   -Recurse -Depth 6 -EA SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](\.git|Pods|build)[\\/]' } | Select-Object -First 1
        $gradleApp = Get-ChildItem -Path $repoRoot -Filter 'build.gradle*' -Recurse -Depth 5 -EA SilentlyContinue | Where-Object { $_.FullName -match '[\\/]app[\\/]' } | Select-Object -First 1

        $fastText  = if ($fastfile)  { Get-Content $fastfile.FullName  -Raw -EA SilentlyContinue } else { '' }
        $matchText = if ($matchfile) { Get-Content $matchfile.FullName -Raw -EA SilentlyContinue } else { '' }
        $gymText   = if ($gymfile)   { Get-Content $gymfile.FullName   -Raw -EA SilentlyContinue } else { '' }
        $appText   = if ($appfile)   { Get-Content $appfile.FullName   -Raw -EA SilentlyContinue } else { '' }

        $isIOS     = $null -ne $podfile -or ($fastText -match 'gym|xcodebuild|match|sigh')
        $isAndroid = $null -ne $gradleApp -or ($fastText -match 'gradle|build_android|supply|upload_to_play_store')

        # ══════════════════════════════════════════════════════════════════════
        # CATEGORY 1: DEPENDENCY GAPS — Gemfile / Pluginfile / Fastfile refs
        # ══════════════════════════════════════════════════════════════════════
        Write-Host "`n[Cat1] Dependencies..."
        if ($null -ne $gemfile) {
            $gemfileText = Get-Content $gemfile.FullName -Raw -EA SilentlyContinue
            $gemfileDir  = Split-Path $gemfile.FullName
            $gemfileRel  = $gemfile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')

            # Gemfile.lock for versions
            $lockVers = @{}
            $lockPath = Join-Path $gemfileDir 'Gemfile.lock'
            if (Test-Path $lockPath) {
                foreach ($lm in [regex]::Matches((Get-Content $lockPath -Raw -EA SilentlyContinue), '^\s{4}([\w_-]+)\s+\(([^)]+)\)', [System.Text.RegularExpressions.RegexOptions]::Multiline)) {
                    $lockVers[$lm.Groups[1].Value] = $lm.Groups[2].Value
                }
            }

            # Build required-gem list
            $required = [System.Collections.Generic.Dictionary[string,string]]::new()
            $required['fastlane'] = 'core runner (always required)'
            if ($isIOS)     { $required['cocoapods'] = 'iOS: Podfile found' }

            # Pluginfile
            # Build plugin file candidate paths safely — avoid piping Join-Path to
            # Join-Path with multiple -ChildPath args (passes array, crashes PS)
            $pluginfile = @(
                (Join-Path (Join-Path $gemfileDir 'fastlane') 'Pluginfile'),
                (Join-Path $gemfileDir 'Pluginfile')
            ) | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($pluginfile) {
                foreach ($pm in [regex]::Matches((Get-Content $pluginfile -Raw -EA SilentlyContinue), 'gem\s+[''"]([^''"]+)[''"]')) {
                    $required[$pm.Groups[1].Value.Trim()] = "listed in Pluginfile"
                }
            }

            # Fastfile patterns
            if ($fastText) {
                foreach ($fm in [regex]::Matches($fastText, 'fastlane_require\s+[''"]([^''"]+)[''"]')) { $required[$fm.Groups[1].Value.Trim()] = "fastlane_require in Fastfile" }
                @{
                    'firebase_app_distribution'     = 'fastlane-plugin-firebase_app_distribution'
                    'increment_build_number_in_plist'= 'fastlane-plugin-versioning'
                    'upload_to_hockey'              = 'fastlane-plugin-hockey'
                    'upload_to_appcenter'           = 'fastlane-plugin-appcenter'
                    'upload_to_deploygate'          = 'fastlane-plugin-deploygate'
                }.GetEnumerator() | ForEach-Object {
                    if ($fastText -match "\b$([regex]::Escape($_.Key))\b") { $required[$_.Value] = "action '$($_.Key)' used in Fastfile" }
                }
            }

            # Missing gem check
            # Safe pattern: single-quoted base + string concatenation for the dynamic gem name.
            # NEVER use  "...\"..."  or  "...``"..."  in PS — use single-quoted strings
            # and concatenation whenever a regex pattern needs a literal double-quote.
            $missing = @($required.Keys | Where-Object {
                $gemfileText -notmatch ('gem\s+[''"]' + [regex]::Escape($_) + '[''"]')
            })
            if ($missing.Count -gt 0) {
                Write-Host "[Cat1] Missing gem(s): $($missing -join ', ')"
                $gemLines   = $gemfileText -split "`r?`n"
                $newContent = $gemfileText.TrimEnd()
                $addedLines = @()
                foreach ($gem in $missing) {
                    $vs = ''
                    if ($lockVers.ContainsKey($gem)) { $lv=$lockVers[$gem]; if ($lv -match '^(\d+\.\d+)') { $vs=", '~> $($matches[1])'" } }
                    elseif ($gem -notlike 'fastlane-plugin-*') { $av=Get-LatestGemVersion -gemName $gem; if ($av) { $vs=", '$av'" } }
                    $nl = "gem '$gem'$vs"; $newContent += "`n$nl"; $addedLines += $nl
                    Write-Host "  [Cat1] + $nl"
                }
                # Title is short by design (card-rendering width, see hitbox note below) —
                # the full gem list still lives in new_code/_fullContent, which is what
                # actually gets applied to the file. Long comma-joined titles (4+ gems)
                # wrap to 4+ lines in Teams' Input.ChoiceSet, and Adaptive Cards' checkbox
                # hitbox can fail to register clicks past the first wrapped line — so cap
                # the displayed names and summarize the rest as a count instead.
                $titleGemList = if ($missing.Count -le 2) {
                    $missing -join ', '
                } else {
                    "$($missing[0]), $($missing[1]) +$($missing.Count - 2) more"
                }
                $fixes.Add([PSCustomObject]@{
                    file_path    = $gemfileRel
                    line_number  = $gemLines.Count + 1
                    title        = "Add $($missing.Count) missing gem(s) to Gemfile: $titleGemList"
                    old_code     = "# --- $(($gemfileText -split "`r?`n").Count) lines already in Gemfile ---"
                    new_code     = ($addedLines -join "`n")
                    confidence   = 0.97
                    _fullContent = $newContent + "`n"
                })
            } else { Write-Host "[Cat1] ✅ All required gems present" }
        } else { Write-Host "[Cat1] ℹ️ No Gemfile found — skipping dependency check" }

        # ══════════════════════════════════════════════════════════════════════
        # CATEGORY 2: CODE SIGNING — auto-detect values, generate code fixes
        # ══════════════════════════════════════════════════════════════════════
        Write-Host "`n[Cat2] Code Signing..."

        # ── Auto-detect Apple Team ID ─────────────────────────────────────────
        $teamId = $null
        if ($isIOS) {
            $pbxproj = Get-ChildItem -Path $repoRoot -Filter 'project.pbxproj' -Recurse -Depth 8 -EA SilentlyContinue |
                       Where-Object { $_.FullName -notmatch '[\\/](Pods|\.git|DerivedData)[\\/]' } | Select-Object -First 1
            if ($pbxproj) {
                $pbxText = Get-Content $pbxproj.FullName -Raw -EA SilentlyContinue
                $teamMatches = [regex]::Matches($pbxText, 'DEVELOPMENT_TEAM = ([A-Z0-9]{10});')
                $firstTM = $teamMatches | Where-Object { $_.Groups[1].Value -ne 'XXXXXXXXXX' } | Select-Object -First 1
                $teamId  = if ($null -ne $firstTM) { $firstTM.Groups[1].Value } else { $null }
            }
            if (-not $teamId -and $matchText -match 'team_id\s*\([''"]([A-Z0-9]{8,12})[''"]') { $teamId = $matches[1] }
            if (-not $teamId -and $fastText  -match 'team_id\s*[=:]\s*[''"]([A-Z0-9]{8,12})[''"]') { $teamId = $matches[1] }
            if ($teamId) { Write-Host "[Cat2] ✅ Apple Team ID auto-detected: $teamId" }
        }

        # ── Auto-detect Bundle ID from Info.plist / project.pbxproj ─────────
        $bundleId = $null
        if ($isIOS) {
            $infoPlist = Get-ChildItem -Path $repoRoot -Filter 'Info.plist' -Recurse -Depth 10 -EA SilentlyContinue |
                         Where-Object { $_.FullName -notmatch '[\\/](Pods|\.git|DerivedData|build|Test|Watch|Share|Widget|Extension|Preview)[\\/]' } |
                         Select-Object -First 1
            if ($infoPlist) {
                $plistText = Get-Content $infoPlist.FullName -Raw -EA SilentlyContinue
                if ($plistText -match '<key>CFBundleIdentifier</key>\s*<string>([^<\$\(]+)</string>') {
                    $bundleId = $matches[1].Trim()
                }
            }
            # Fallback: project.pbxproj
            if (-not $bundleId -and $pbxText) {
                $firstBid = [regex]::Matches($pbxText,'PRODUCT_BUNDLE_IDENTIFIER = ([^;\s]+);') |
                            Where-Object { $_.Groups[1].Value -notmatch '^\$|Test|Watch|Widget|Share' } |
                            Select-Object -First 1
                $bid = if ($null -ne $firstBid) { $firstBid.Groups[1].Value } else { $null }
                if ($bid) { $bundleId = $bid }
            }
            if ($bundleId) { Write-Host "[Cat2] ✅ Bundle ID auto-detected: $bundleId" }
        }

        # ── Auto-detect workspace/scheme from .xcworkspace ───────────────────
        $wsName     = $null
        $schemeName = $null
        if ($isIOS) {
            $xcws = Get-ChildItem -Path $repoRoot -Filter '*.xcworkspace' -Recurse -Depth 6 -EA SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '[\\/](Pods|\.git|DerivedData|Carthage)[\\/]' -and $_.Name -ne 'project.xcworkspace' } |
                    Select-Object -First 1
            if ($xcws) {
                $wsName = [IO.Path]::GetFileNameWithoutExtension($xcws.FullName)
                # Try xcodebuild -list to get real scheme names
                try {
                    $xbOut = & xcodebuild -list -workspace $xcws.FullName 2>&1 | Out-String
                    $inS   = $false
                    foreach ($xl in ($xbOut -split "`n")) {
                        if ($xl -match '^\s+Schemes?:') { $inS = $true; continue }
                        if ($inS -and $xl.Trim() -ne '') { $schemeName = $xl.Trim(); break }
                        if ($inS -and $xl.Trim() -eq '') { break }
                    }
                } catch {}
                if (-not $schemeName) { $schemeName = $wsName }  # same name is the common convention
                Write-Host "[Cat2] ✅ Workspace auto-detected: $wsName  Scheme: $schemeName"
            }
        }

        # ── Appfile: inject team_id + app_identifier if missing ──────────────
        if ($isIOS) {
            $needTeam   = $appText -notmatch 'team_id\s*\(' -and $teamId
            $needBundle = $appText -notmatch 'app_identifier\s*\(' -and $bundleId
            if (($needTeam -or $needBundle) -and $appfile) {
                $appRel  = $appfile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
                $newApp  = $appText.TrimEnd(); $appAdded = @()
                if ($needBundle) { $newApp += "`napp_identifier(`"$bundleId`")"; $appAdded += "app_identifier(`"$bundleId`")" }
                if ($needTeam)   { $newApp += "`nteam_id(`"$teamId`")";          $appAdded += "team_id(`"$teamId`")" }
                $fixes.Add([PSCustomObject]@{
                    file_path    = $appRel
                    line_number  = ($appText -split "`r?`n").Count + 1
                    title        = "Auto-detected: add $($appAdded.Count) value(s) to Appfile from project files"
                    old_code     = "# Appfile — values auto-detected from project.pbxproj / Info.plist"
                    new_code     = ($appAdded -join "`n")
                    confidence   = 0.91
                    _fullContent = $newApp + "`n"
                })
                Write-Host "[Cat2] ✅ Appfile code fix: $($appAdded -join ', ')"
            } elseif ($needTeam -or $needBundle) {
                # No Appfile — create one
                $appDir = if ($fastfile) { Split-Path $fastfile.FullName } else { Join-Path $repoRoot 'fastlane' }
                $newAppContent = "# Appfile — auto-generated by AI triage`n"
                if ($bundleId) { $newAppContent += "app_identifier(`"$bundleId`")`n" }
                if ($teamId)   { $newAppContent += "team_id(`"$teamId`")`n" }
                $appRel2 = (Join-Path 'fastlane' 'Appfile').Replace('\','/')
                $fixes.Add([PSCustomObject]@{
                    file_path    = $appRel2; line_number = 1
                    title        = "Create Appfile with auto-detected bundle_id/team_id"
                    old_code     = "# (Appfile did not exist)"
                    new_code     = $newAppContent.Trim()
                    confidence   = 0.88; _fullContent = $newAppContent
                })
                Write-Host "[Cat2] ✅ Creating Appfile with auto-detected values"
            } elseif (-not $teamId -and $appText -notmatch 'team_id\s*\(') {
                $fixes.Add((New-ManualActionFix -Category 'CodeSigning' `
                    -Title 'Apple Team ID: not found in project files — set manually' `
                    -Instructions "Add to fastlane/Appfile:`n  team_id(`"YOUR_APPLE_TEAM_ID`")`n`nFind it at: developer.apple.com → Account → Membership Details → Team ID (10-char alphanumeric)" `
                    -Confidence 0.75))
            }

            # ── Gymfile: inject workspace + scheme with real detected names ────
            if ($gymfile -and ($gymText -notmatch 'workspace\s*\(' -or $gymText -notmatch 'scheme\s*\(')) {
                $gymRel  = $gymfile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
                $newGym  = $gymText; $gymAdded = @()
                if ($gymText -notmatch 'workspace\s*\(') {
                    $wsVal = if ($wsName) { $wsName } else { 'YOUR_APP.xcworkspace' }
                    $newGym = "workspace(`"$wsVal`")`n" + $newGym; $gymAdded += "workspace(`"$wsVal`")"
                }
                if ($gymText -notmatch 'scheme\s*\(') {
                    $schVal = if ($schemeName) { $schemeName } else { 'YOUR_SCHEME' }
                    $newGym = "scheme(`"$schVal`")`n" + $newGym; $gymAdded += "scheme(`"$schVal`")"
                }
                $fixes.Add([PSCustomObject]@{
                    file_path    = $gymRel; line_number = 1
                    title        = "Add to Gymfile: $($gymAdded -join ', ')$(if($wsName){' (auto-detected from .xcworkspace)'})"
                    old_code     = "# Gymfile — missing workspace/scheme settings"
                    new_code     = ($gymAdded -join "`n")
                    confidence   = if ($wsName) { 0.93 } else { 0.75 }
                    _fullContent = $newGym
                })
                Write-Host "[Cat2] ✅ Gymfile code fix: $($gymAdded -join ', ')"
            }

            # ── Match auth: stays MANUAL (secret password cannot be auto-set) ──
            if ($fastText -match '\bmatch\b' -and
                [string]::IsNullOrWhiteSpace($env:MATCH_PASSWORD) -and
                [string]::IsNullOrWhiteSpace($env:MATCH_GIT_BASIC_AUTHORIZATION)) {
                $fixes.Add((New-ManualActionFix -Category 'CodeSigning' `
                    -Title 'MATCH_PASSWORD not set — the only item that cannot be auto-fixed (secret value)' `
                    -Instructions "ADO → Library → Variable Groups → your-group → Add:`n  MATCH_PASSWORD = <passphrase from when you ran 'fastlane match init'>`n`nThis is the ONLY change needed — the Fastfile and Matchfile already reference it correctly." `
                    -Confidence 0.95))
                Write-Host "[Cat2] ⚠️ MATCH_PASSWORD: stays MANUAL (secret value)"
            }

            # ── Cert/profile expiry (from log) ────────────────────────────────
            if ($logText -match '(?i)(certificate.*expired|profile.*expired|signing.*certificate.*no longer valid|provision.*expired)') {
                $fixes.Add((New-ManualActionFix -Category 'CodeSigning' `
                    -Title 'Certificate or provisioning profile has expired — run: fastlane match nuke + match' `
                    -Instructions "Run locally (MATCH_PASSWORD must be set):`n  fastlane match nuke distribution`n  fastlane match distribution`n  fastlane match appstore   # if App Store profiles also needed" `
                    -Confidence 0.95))
            }
        }

        # ── Android: generate signingConfig code fix ─────────────────────────
        if ($isAndroid -and $gradleApp) {
            $gradleText = Get-Content $gradleApp.FullName -Raw -EA SilentlyContinue
            $gradleRel  = $gradleApp.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
            if ($gradleText -notmatch 'signingConfigs' -and ($fastText -match 'gradle.*release|build_type.*release' -or $gradleText -match 'buildTypes.*release')) {
                $signingBlock = "`n    signingConfigs {`n        release {`n            storeFile     file(System.getenv(`"SIGNING_STORE_FILE`") ?: `"keystore.jks`")`n            storePassword (System.getenv(`"SIGNING_STORE_PASSWORD`") ?: `"`")`n            keyAlias      (System.getenv(`"SIGNING_KEY_ALIAS`")      ?: `"`")`n            keyPassword   (System.getenv(`"SIGNING_KEY_PASSWORD`")   ?: `"`")`n        }`n    }"
                $newGradle = $gradleText -replace '(?s)(android\s*\{)', "`$1$signingBlock"
                if ($newGradle -ne $gradleText) {
                    $fixes.Add([PSCustomObject]@{
                        file_path    = $gradleRel; line_number = 1
                        title        = "Add Android signingConfig to build.gradle — reads SIGNING_* from pipeline env vars"
                        old_code     = "android {"
                        new_code     = "android {`n    signingConfigs { release { storeFile, storePassword, keyAlias, keyPassword from ENV } } }"
                        confidence   = 0.88; _fullContent = $newGradle
                    })
                    $fixes.Add((New-ManualActionFix -Category 'CodeSigning' `
                        -Title 'Upload .jks keystore to ADO Secure Files and set SIGNING_* variables (code fix already in PR)' `
                        -Instructions "1. ADO Library → Secure Files → Upload your keystore.jks`n2. ADO Library → Variable Groups → Add:`n   SIGNING_STORE_FILE     = `$(keystore.jks.secureFilePath)`n   SIGNING_KEY_ALIAS      = <your-alias>`n   SIGNING_STORE_PASSWORD = <store-password>`n   SIGNING_KEY_PASSWORD   = <key-password>" `
                        -Confidence 0.90))
                    Write-Host "[Cat2] ✅ Android signingConfig code fix added"
                }
            }
        }

        # ══════════════════════════════════════════════════════════════════════
        # CATEGORY 3: DISTRIBUTION — Fastfile code fixes for all platforms
        # ══════════════════════════════════════════════════════════════════════
        Write-Host "`n[Cat3] Distribution..."
        if ($fastfile -and $fastText) {
            $fastRel = $fastfile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')

            # $effFast tracks the cumulative state of the Fastfile across all Cat3 modifications.
            # Each block (Firebase / ASC / Play Store) modifies $effFast in sequence so the
            # final PR contains ALL changes in one coherent file — not each one overwriting the last.
            # Presence-checks (-notmatch 'already-present') still use the original $fastText so
            # we don't skip a block just because a prior block added unrelated content.
            $effFast = $fastText

            # ── Firebase: detect App ID, update Fastfile with env var refs ────
            if ($fastText -match 'firebase_app_distribution') {
                $hasCred = -not [string]::IsNullOrWhiteSpace($env:FIREBASE_TOKEN) -or
                           -not [string]::IsNullOrWhiteSpace($env:GOOGLE_APPLICATION_CREDENTIALS)
                # Auto-detect FIREBASE_APP_ID from GoogleService-Info.plist / google-services.json
                $fbAppId = $null
                $gsPlist = Get-ChildItem -Path $repoRoot -Filter 'GoogleService-Info.plist' -Recurse -Depth 8 -EA SilentlyContinue |
                           Where-Object { $_.FullName -notmatch '[\\/](\.git|Pods|DerivedData)[\\/]' } | Select-Object -First 1
                if ($gsPlist) {
                    $gsText = Get-Content $gsPlist.FullName -Raw -EA SilentlyContinue
                    if ($gsText -match '<key>GOOGLE_APP_ID</key>\s*<string>([^<]+)</string>') { $fbAppId = $matches[1].Trim() }
                }
                $gsJson = Get-ChildItem -Path $repoRoot -Filter 'google-services.json' -Recurse -Depth 8 -EA SilentlyContinue |
                          Where-Object { $_.FullName -notmatch '[\\/](\.git|build)[\\/]' } | Select-Object -First 1
                if (-not $fbAppId -and $gsJson) {
                    try { $gj = Get-Content $gsJson.FullName -Raw -EA SilentlyContinue | ConvertFrom-Json; $fbAppId = $gj.client[0].client_info.mobilesdk_app_id } catch {}
                }
                if ($fbAppId) { Write-Host "[Cat3] ✅ Firebase App ID auto-detected: $fbAppId" }

                # Update Fastfile to reference env vars if credential refs are missing
                if (-not $hasCred -and $fastText -notmatch 'FIREBASE_TOKEN|GOOGLE_APPLICATION_CREDENTIALS|firebase_cli_token|service_credentials_file') {
                    $appLine  = if ($fbAppId) { "    app: `"$fbAppId`"," } else { "    app: ENV[`"FIREBASE_APP_ID`"]," }
                    $credBlock = "`n    # AI-triage: credential env vars added automatically`n$appLine`n    firebase_cli_token: ENV[`"FIREBASE_TOKEN`"],"
                    $newFast  = [regex]::Replace($effFast,'(?s)(firebase_app_distribution\s*\()',"`$1$credBlock")
                    if ($newFast -ne $effFast) {
                        $fixes.Add([PSCustomObject]@{
                            file_path    = $fastRel; line_number = 1
                            title        = "Update Fastfile: add Firebase credential env var refs to firebase_app_distribution()$(if($fbAppId){' — App ID auto-detected'})"
                            old_code     = "firebase_app_distribution("
                            new_code     = "firebase_app_distribution(`n    app: $(if($fbAppId){$fbAppId}else{'ENV[FIREBASE_APP_ID]'}),`n    firebase_cli_token: ENV[FIREBASE_TOKEN],"
                            confidence   = 0.88; _fullContent = $newFast
                        })
                        $fixes.Add((New-ManualActionFix -Category 'Distribution' `
                            -Title "Set FIREBASE_TOKEN in ADO Library (Fastfile already updated by PR$(if($fbAppId){' — App ID auto-detected: '+$fbAppId}))" `
                            -Instructions "Run: firebase login:ci → copy the token`nADO Library → Variable Groups → Add: FIREBASE_TOKEN = <token>" `
                            -Confidence 0.92))
                        $effFast = $newFast   # accumulate: ASC/Play blocks build on this
                        Write-Host "[Cat3] ✅ Fastfile updated with Firebase credential refs"
                    }
                } else { Write-Host "[Cat3] ✅ Firebase credentials configured" }
            }

            # ── App Store Connect: add api_key block to Fastfile ──────────────
            if ($fastText -match 'upload_to_testflight|upload_to_app_store|deliver\b|pilot\b') {
                $hasAsc = -not [string]::IsNullOrWhiteSpace($env:ASC_KEY_ID) -or -not [string]::IsNullOrWhiteSpace($env:FASTLANE_PASSWORD)
                if (-not $hasAsc -and $fastText -notmatch 'app_store_connect_api_key|ASC_KEY_ID|FASTLANE_PASSWORD') {
                    $apiBlock  = "  # AI-triage: App Store Connect API key block added automatically`n  api_key = app_store_connect_api_key(`n    key_id:      ENV[`"ASC_KEY_ID`"],`n    issuer_id:   ENV[`"ASC_ISSUER_ID`"],`n    key_content: ENV[`"ASC_KEY_CONTENT`"]`n  )`n"
                    # Apply to $effFast (may already include Firebase changes) not original $fastText
                    $newFast2  = $effFast -replace '(?s)([ \t]*)(upload_to_testflight|upload_to_app_store|deliver|pilot)(\s*\()', "$apiBlock`$1`$2`$3`n    api_key: api_key,"
                    if ($newFast2 -ne $effFast) {
                        $fixes.Add([PSCustomObject]@{
                            file_path    = $fastRel; line_number = 1
                            title        = "Update Fastfile: add app_store_connect_api_key() block for TestFlight/App Store upload"
                            old_code     = "upload_to_testflight("
                            new_code     = "api_key = app_store_connect_api_key(key_id: ENV[ASC_KEY_ID], ...)`nupload_to_testflight(api_key: api_key, ...)"
                            confidence   = 0.85; _fullContent = $newFast2
                        })
                        $fixes.Add((New-ManualActionFix -Category 'Distribution' `
                            -Title "Set ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_CONTENT in ADO Library (Fastfile already updated by PR)" `
                            -Instructions "App Store Connect → Users & Access → Integrations → API Keys → Create → download .p8`nADO Library → Variable Groups → Add:`n  ASC_KEY_ID     = <Key ID>`n  ASC_ISSUER_ID  = <Issuer UUID>`n  ASC_KEY_CONTENT = <base64 of .p8:  base64 AuthKey_XXX.p8>" `
                            -Confidence 0.90))
                        $effFast = $newFast2   # accumulate: Play Store block builds on this
                        Write-Host "[Cat3] ✅ Fastfile updated with ASC api_key block"
                    }
                } else { Write-Host "[Cat3] ✅ App Store Connect configured" }
            }

            # ── Google Play: add json_key_file ref to Fastfile ───────────────
            if ($fastText -match 'upload_to_play_store|supply\b') {
                $hasPlay = -not [string]::IsNullOrWhiteSpace($env:PLAY_STORE_JSON_KEY) -or -not [string]::IsNullOrWhiteSpace($env:SUPPLY_JSON_KEY)
                if (-not $hasPlay -and $fastText -notmatch 'json_key_file|PLAY_STORE_JSON_KEY') {
                    # Apply to $effFast (may already include Firebase+ASC changes)
                    $newFast3 = $effFast -replace '(?s)(upload_to_play_store|supply)\s*\(', "`$0`n    json_key_file: ENV[`"PLAY_STORE_JSON_KEY`"],"
                    if ($newFast3 -ne $effFast) {
                        $fixes.Add([PSCustomObject]@{
                            file_path    = $fastRel; line_number = 1
                            title        = "Update Fastfile: add json_key_file from ENV[PLAY_STORE_JSON_KEY] to Google Play upload"
                            old_code     = "upload_to_play_store("
                            new_code     = "upload_to_play_store(`n    json_key_file: ENV[PLAY_STORE_JSON_KEY],"
                            confidence   = 0.87; _fullContent = $newFast3
                        })
                        $fixes.Add((New-ManualActionFix -Category 'Distribution' `
                            -Title "Upload Google Play service account JSON and set PLAY_STORE_JSON_KEY (Fastfile already updated by PR)" `
                            -Instructions "Google Play Console → Setup → API access → Service account → Download JSON`nADO Library → Secure Files → Upload as play-store-key.json`nADO Library → Variable Groups → Add: PLAY_STORE_JSON_KEY = `$(play-store-key.json.secureFilePath)" `
                            -Confidence 0.90))
                        $effFast = $newFast3   # accumulate for any further blocks
                        Write-Host "[Cat3] ✅ Fastfile updated with Google Play json_key_file ref"
                    }
                } else { Write-Host "[Cat3] ✅ Google Play configured" }
            }

            # ── App Center ────────────────────────────────────────────────────
            if ($fastText -match 'appcenter_upload|upload_to_appcenter') {
                if ([string]::IsNullOrWhiteSpace($env:APPCENTER_API_TOKEN)) {
                    $fixes.Add((New-ManualActionFix -Category 'Distribution' `
                        -Title "Set APPCENTER_API_TOKEN in ADO Library — no code change needed" `
                        -Instructions "AppCenter.ms → Account Settings → API Tokens → Add (Full Access)`nADO Library → Variable Groups → Add: APPCENTER_API_TOKEN = <token>" `
                        -Confidence 0.88))
                }
            }
        }

        # ══════════════════════════════════════════════════════════════════════
        # CATEGORY 4: ENVIRONMENT — auto-detect and fix where possible
        # ══════════════════════════════════════════════════════════════════════
        Write-Host "`n[Cat4] Environment..."
        $unresolvedVars = [regex]::Matches($logText,'\$\(([A-Z][A-Z0-9_]{2,})\)') |
                          ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique |
                          Where-Object { $_ -notmatch '^(Build|System|Agent|Pipeline|Release|Stage|Job|TF_BUILD|AZURE|AZP)' }
        foreach ($uv in $unresolvedVars) {
            if ($uv -eq 'BUNDLER_VERSION' -and $gemfile) {
                # Auto-detect from Gemfile.lock "BUNDLED WITH x.x.x"
                $bv = $null
                $lp = Join-Path (Split-Path $gemfile.FullName) 'Gemfile.lock'
                if (Test-Path $lp) {
                    $lt = Get-Content $lp -Raw -EA SilentlyContinue
                    if ($lt -match 'BUNDLED WITH\s+(\d+\.\d+\.\d+)') { $bv = $matches[1] }
                }
                if (-not $bv) { try { $bv = (& gem list bundler 2>$null | Select-String '(\d+\.\d+\.\d+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1) } catch {} }
                if ($bv) {
                    # Find YAML file that uses $(BUNDLER_VERSION) and patch it inline
                    $yf = Get-ChildItem -Path $repoRoot -Filter '*.yml' -Recurse -Depth 8 -EA SilentlyContinue |
                          Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } |
                          Where-Object { (Get-Content $_.FullName -Raw -EA SilentlyContinue) -match '\$\(BUNDLER_VERSION\)' } | Select-Object -First 1
                    if ($yf) {
                        $yt  = Get-Content $yf.FullName -Raw -EA SilentlyContinue
                        $yr  = $yf.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
                        $fixes.Add([PSCustomObject]@{
                            file_path    = $yr; line_number = 1
                            title        = "Auto-fix: replace unresolved `$(BUNDLER_VERSION) with $bv (detected from Gemfile.lock)"
                            old_code     = '$(BUNDLER_VERSION)'; new_code = $bv
                            confidence   = 0.95; _fullContent = ($yt -replace '\$\(BUNDLER_VERSION\)', $bv)
                        })
                        Write-Host "[Cat4] ✅ BUNDLER_VERSION auto-resolved: $bv"
                    }
                } else {
                    $fixes.Add((New-ManualActionFix -Category 'Environment' `
                        -Title "Set BUNDLER_VERSION in ADO Library (auto-detect from Gemfile.lock failed)" `
                        -Instructions "ADO Library → Variable Groups → Add: BUNDLER_VERSION = 2.4.22 (check via: bundler --version)" `
                        -Confidence 0.85))
                }
            } else {
                # BUGFIX: the title/log strings below only escaped the leading `$` of the
                # literal text "$(VARNAME)" with a backtick, not the parens. In a PowerShell
                # double-quoted string, an escaped `$` followed by a bare ( is just two literal
                # characters -- but the immediately following $uv is its own UNESCAPED variable
                # reference, and the closing ) after it is literal too, leaving a stray, unmatched
                # extra "(" right after it (the one originally intended to open "$(uv)" never
                # got consumed as a subexpression because the $ before it was already escaped).
                # Net effect: rendered text was "$(ROSETTA2_WARNING)( not resolved..." -- a
                # visibly broken extra "(" in every one of these manual-action titles. Fixed by
                # escaping the `$`, the opening `(`, AND the closing `)` individually, leaving
                # only $uv itself as the live interpolation.
                $fixes.Add((New-ManualActionFix -Category 'Environment' `
                    -Title "ADO variable `$(`$uv`) not resolved — set in ADO Library" `
                    -Instructions "ADO Library → Variable Groups → Add: $uv = <value>`nEnsure variable group is linked to this pipeline." `
                    -Confidence 0.90))
                Write-Host "[Cat4] ❌ Unresolved: `$(`$uv`)"
            }
        }

        # ── Ruby version mismatch → add UseRubyVersion@0 task to pipeline YAML
        $rvFile = Join-Path $repoRoot '.ruby-version'
        if (Test-Path $rvFile) {
            $reqRuby = (Get-Content $rvFile -Raw -EA SilentlyContinue).Trim()
            try { $actRuby = & ruby -e 'print RUBY_VERSION' 2>$null } catch { $actRuby = '' }
            if ($reqRuby -and $actRuby -and $reqRuby -ne $actRuby) {
                $pipeYaml = Get-ChildItem -Path $repoRoot -Filter 'azure-pipelines*.yml' -Recurse -Depth 4 -EA SilentlyContinue | Select-Object -First 1
                if ($pipeYaml) {
                    $pyText = Get-Content $pipeYaml.FullName -Raw -EA SilentlyContinue
                    $pyRel  = $pipeYaml.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
                    if ($pyText -notmatch 'UseRubyVersion') {
                        $rubyTask = "- task: UseRubyVersion@0`n  inputs:`n    versionSpec: '$reqRuby'`n"
                        $fixes.Add([PSCustomObject]@{
                            file_path    = $pyRel; line_number = 1
                            title        = "Add UseRubyVersion@0 to pipeline YAML: requires $reqRuby, agent has $actRuby"
                            old_code     = "# (no UseRubyVersion task present)"; new_code = $rubyTask.Trim()
                            confidence   = 0.85; _fullContent = $rubyTask + $pyText
                        })
                        Write-Host "[Cat4] ✅ UseRubyVersion@0 code fix added for $reqRuby"
                    }
                } else {
                    $fixes.Add((New-ManualActionFix -Category 'Environment' `
                        -Title "Ruby version mismatch: .ruby-version=$reqRuby but agent has $actRuby" `
                        -Instructions "Add to pipeline YAML before bundle install:`n  - task: UseRubyVersion@0`n    inputs:`n      versionSpec: '$reqRuby'" `
                        -Confidence 0.88))
                }
            }
        }

        $totalFixes  = $fixes.Count
        $codeFixes   = @($fixes | Where-Object { $_.title -notmatch 'MANUAL ACTION' }).Count
        $manualFixes = $totalFixes - $codeFixes
        Write-Host "`n[Preflight] ✅ $totalFixes issue(s): $codeFixes code PR fix(es), $manualFixes manual action(s)`n"
        return $fixes
    }

    # ── COCOAPODS MISSING POD AUTO-FIX ──────────────────────────────────────────
    # Detects "Unable to find a specification for 'X'" — a CocoaPods runtime error
    # that means the Podfile references a pod that doesn't exist in the spec repos
    # OR that `pod install` hasn't been run yet.
    # Fix: add `pod 'X'` to the Podfile so the next `pod install` picks it up.
    # Zero AI tokens — deterministic pod name extraction from build log.
    function Get-CocoaPodsFixes {
        param([string]$logText)
        $fixes = [System.Collections.Generic.List[object]]::new()

        $missingPods = [System.Collections.Generic.List[string]]::new()
        $patterns = @(
            "Unable to find a specification for '([^'@\s]+)",
            "Unable to satisfy the following requirements:.*?'([A-Za-z0-9_.\-]+)\s*[~><=]",
            "Could not find compatible versions for pod '([^']+)'",
            "None of your spec sources contain a spec satisfying the dependency.*?'([A-Za-z0-9_.\-]+)"
        )
        foreach ($pat in $patterns) {
            foreach ($m in [regex]::Matches($logText, $pat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase + 'Singleline')) {
                $pod = $m.Groups[1].Value.Trim()
                if (-not [string]::IsNullOrWhiteSpace($pod) -and -not $missingPods.Contains($pod)) {
                    $missingPods.Add($pod)
                }
            }
        }

        if ($missingPods.Count -eq 0) { return $fixes }
        Write-Host "[PodFix] Missing CocoaPod(s): $($missingPods -join ', ')"

        $repoRoot = $env:BUILD_SOURCESDIRECTORY
        $podFile = Get-ChildItem -Path $repoRoot -Filter 'Podfile' -Recurse -Depth 8 -EA SilentlyContinue |
                   Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|vendor|Pods)[\\/]' } |
                   Select-Object -First 1

        if ($null -eq $podFile) {
            Write-Host "[PodFix] ⚠️ No Podfile found in repo — cannot auto-fix."
            return $fixes
        }

        $podRelPath = $podFile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
        $podContent = Get-Content $podFile.FullName -Raw -EA SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($podContent)) { return $fixes }
        $podLines = $podContent -split "`r?`n"

        # ── Podfile.lock version lookup ──────────────────────────────────────
        # When a pod is removed from Podfile and re-added, restore the exact
        # version that was working. Podfile.lock format:
        #   PODS:
        #     - Firebase/Core (10.12.0)
        $podLockVersions = @{}
        $podLockPath = Join-Path (Split-Path $podFile.FullName) 'Podfile.lock'
        if (Test-Path $podLockPath) {
            $podLockText = Get-Content $podLockPath -Raw -EA SilentlyContinue
            foreach ($lm in [regex]::Matches($podLockText, '^\s+- ([\w/]+)\s+\(([^)]+)\)', [System.Text.RegularExpressions.RegexOptions]::Multiline)) {
                $podName = $lm.Groups[1].Value.Trim()
                $podVer  = $lm.Groups[2].Value.Trim()
                if (-not $podLockVersions.ContainsKey($podName)) {
                    $podLockVersions[$podName] = $podVer
                }
            }
            Write-Host "[PodFix] Read $($podLockVersions.Count) version(s) from Podfile.lock"
        }

        foreach ($pod in $missingPods) {
            if ($podContent -match "pod\s+'$([regex]::Escape($pod))'") {
                Write-Host "[PodFix] '$pod' already in Podfile — skipping"
                continue
            }

            # Use Podfile.lock version if available; otherwise query CocoaPods Trunk API
            $verStr = ''
            if ($podLockVersions.ContainsKey($pod)) {
                $verStr = ", '~> $($podLockVersions[$pod] -replace '\.\d+$','')'"
                Write-Host "[PodFix] Using Podfile.lock version for '$pod': $($podLockVersions[$pod])"
            } else {
                # No lock file entry — query CocoaPods Trunk for the latest stable version
                $apiVer = Get-LatestPodVersion -podName $pod
                if ($apiVer) { $verStr = ", '$apiVer'" }
            }

            Write-Host "[PodFix] ✅ Queuing fix: add pod '$pod'$verStr to $podRelPath"
            $newPodLine = "  pod '$pod'$verStr"
            $newContent = ($podLines + @($newPodLine)) -join "`n"
            $lastLine   = if ($podLines.Count -gt 0) { $podLines[-1] } else { '' }
            $fixes.Add([PSCustomObject]@{
                file_path    = $podRelPath
                line_number  = $podLines.Count + 1
                title        = "Add missing CocoaPod: '$pod'$verStr to Podfile"
                old_code     = $lastLine
                new_code     = $lastLine + "`n$newPodLine"
                confidence   = 0.90
                _fullContent = $newContent
            })
        }
        return $fixes
    }

    # ── NPM/NODE.JS MISSING MODULE AUTO-FIX ─────────────────────────────────────
    # Detects "Cannot find module 'X'" and "Module not found: Can't resolve 'X'"
    # — node.js runtime / webpack errors that mean a package is missing from
    # package.json / node_modules.
    # Fix: add the missing module to package.json devDependencies or dependencies,
    # so the next `npm install` / CI setup step picks it up.
    # Heuristic: @types/*, jest*, eslint*, webpack*, babel*, ts-* → devDependency.
    # All others → dependency.
    # Zero AI tokens — deterministic module name extraction.
    function Get-NpmModuleFixes {
        param([string]$logText)
        $fixes = [System.Collections.Generic.List[object]]::new()

        $missingMods = [System.Collections.Generic.List[string]]::new()
        $modPatterns = @(
            "Cannot find module '([^'./][^']*)'",
            "Module not found: Error: Can't resolve '([^'./][^']*)'",
            "npm ERR! missing: ([^\s@][^\s]*)\@",
            "ModuleNotFoundError: No module named '([A-Za-z][^']*)'",
            "Cannot resolve module '([^'./][^']*)'",
            # ── command not found — npm binary removed from devDependencies ─
            'bundler: command not found: ([a-zA-Z][\w_-]+)',
            'sh: \d+: ([a-zA-Z][\w_@/-]+): not found',
            "command not found: ([a-zA-Z][\w_@/-]+)",
            'bash: ([a-zA-Z][\w_@/-]+): command not found',
            # npm-specific script errors
            "npm ERR! code E404.*'([^'@][^']*)@",
            'npm warn.*missing.*"([^"@][^"]*)"'
        )
        # Node.js built-in modules — never need to install
        $builtins = @('fs','path','os','http','https','url','events','stream','util','crypto',
                      'zlib','buffer','child_process','cluster','net','dns','tls','readline',
                      'repl','vm','process','assert','querystring','string_decoder','timers',
                      'module','constants','domain','v8','punycode','inspector')

        # ── Binary → npm package name mapping ──────────────────────────────
        # "command not found: jest" means 'jest' package missing from devDependencies
        $binaryToNpm = @{
            'jest'           = 'jest'
            'vitest'         = 'vitest'
            'mocha'          = 'mocha'
            'webpack'        = 'webpack'
            'webpack-cli'    = 'webpack-cli'
            'vite'           = 'vite'
            'rollup'         = 'rollup'
            'esbuild'        = 'esbuild'
            'tsc'            = 'typescript'
            'ts-node'        = 'ts-node'
            'eslint'         = 'eslint'
            'prettier'       = 'prettier'
            'babel'          = '@babel/core'
            'react-scripts'  = 'react-scripts'
            'next'           = 'next'
            'expo'           = 'expo-cli'
            'ng'             = '@angular/cli'
            'vue'            = '@vue/cli'
            'nuxt'           = 'nuxt'
            'svelte-kit'     = '@sveltejs/kit'
            'parcel'         = 'parcel'
            'nodemon'        = 'nodemon'
            'concurrently'   = 'concurrently'
            'cross-env'      = 'cross-env'
            'rimraf'         = 'rimraf'
            'copyfiles'      = 'copyfiles'
            'node'           = $null   # Node runtime — skip
            'npm'            = $null   # npm itself — skip
            'yarn'           = $null   # yarn — skip
            'npx'            = $null   # npx — skip
        }

        foreach ($pat in $modPatterns) {
            foreach ($m in [regex]::Matches($logText, $pat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $raw = $m.Groups[1].Value.Trim() -replace '/.*','' -replace '\?.*',''
                # Resolve binary → npm package
                if ($binaryToNpm.ContainsKey($raw)) {
                    $resolved = $binaryToNpm[$raw]
                    if ($null -eq $resolved) { continue }
                    $raw = $resolved
                }
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                if ($builtins -contains $raw.ToLower()) { continue }
                if ($raw -match '^(\d|\.|\(|#|@.*/)') { continue }
                if (-not $missingMods.Contains($raw)) { $missingMods.Add($raw) }
            }
        }

        if ($missingMods.Count -eq 0) { return $fixes }
        Write-Host "[NpmFix] Missing npm module(s): $($missingMods -join ', ')"

        $repoRoot = $env:BUILD_SOURCESDIRECTORY
        $pkgFile = Get-ChildItem -Path $repoRoot -Filter 'package.json' -Recurse -Depth 6 -EA SilentlyContinue |
                   Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git|dist|build|coverage|\.yarn)[\\/]' } |
                   Select-Object -First 1

        if ($null -eq $pkgFile) {
            Write-Host "[NpmFix] ⚠️ No package.json found — cannot auto-fix."
            return $fixes
        }

        $pkgRelPath = $pkgFile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
        $pkgContent = Get-Content $pkgFile.FullName -Raw -EA SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($pkgContent)) { return $fixes }

        # ── Lock file version lookup ─────────────────────────────────────────
        # Priority: package-lock.json (npm) → yarn.lock → .yarnrc.yml (berry)
        # When a package was previously installed, get its exact version from the
        # lock file and use "^X.Y.Z" so the manifest stays consistent.
        $lockVersions = @{}
        $lockCandidates = @(
            Join-Path (Split-Path $pkgFile.FullName) 'package-lock.json',
            Join-Path (Split-Path $pkgFile.FullName) 'yarn.lock'
        )
        foreach ($lc in $lockCandidates) {
            if (-not (Test-Path $lc)) { continue }
            $lockText = Get-Content $lc -Raw -EA SilentlyContinue
            if ($lc -like '*package-lock.json') {
                # npm lock: "node_modules/jest": { "version": "29.5.0" }
                foreach ($lm in [regex]::Matches($lockText, '"node_modules/([\w@/-]+)"[^{]*\{[^}]*"version":\s*"([^"]+)"', [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
                    $lockVersions[$lm.Groups[1].Value] = $lm.Groups[2].Value
                }
            } elseif ($lc -like '*yarn.lock') {
                # yarn lock: jest@^29.0.0:\n  version "29.5.0"
                foreach ($lm in [regex]::Matches($lockText, '^"?([\w@][^@\n"]+)@[^:]+:\s*\n\s+version\s+"([^"]+)"', [System.Text.RegularExpressions.RegexOptions]::Multiline)) {
                    $lockVersions[$lm.Groups[1].Value] = $lm.Groups[2].Value
                }
            }
            if ($lockVersions.Count -gt 0) {
                Write-Host "[NpmFix] Read $($lockVersions.Count) version(s) from $(Split-Path $lc -Leaf)"
                break
            }
        }

        try {
            $pkg = $pkgContent | ConvertFrom-Json -Depth 20 -EA Stop
            $changed = $false
            $devPattern = '^(@types/|jest|vitest|mocha|chai|jasmine|eslint|prettier|webpack|babel|ts-node|typescript|nodemon|husky|lint-staged|rollup|vite|esbuild|rimraf|concurrently|cross-env|copyfiles)'

            foreach ($mod in $missingMods) {
                $inDeps    = $null -ne $pkg.dependencies    -and $null -ne $pkg.dependencies.PSObject.Properties[$mod]
                $inDevDeps = $null -ne $pkg.devDependencies -and $null -ne $pkg.devDependencies.PSObject.Properties[$mod]
                if ($inDeps -or $inDevDeps) {
                    Write-Host "[NpmFix] '$mod' already in package.json — skipping"
                    continue
                }

                # Determine version — prefer lock file, then npm registry, never 'latest' if avoidable
                $verStr = 'latest'   # final fallback only when registry is unreachable
                if ($lockVersions.ContainsKey($mod)) {
                    $lv = $lockVersions[$mod]
                    if ($lv -match '^(\d+\.\d+)') { $verStr = "^$lv" }
                } else {
                    # Query npm registry for the current latest stable version
                    $apiVer = Get-LatestNpmVersion -packageName $mod
                    if ($apiVer) { $verStr = $apiVer }
                }

                $isDev = $mod -match $devPattern
                if ($isDev) {
                    if ($null -eq $pkg.devDependencies) { $pkg | Add-Member -MemberType NoteProperty -Name devDependencies -Value ([PSCustomObject]@{}) }
                    $pkg.devDependencies | Add-Member -MemberType NoteProperty -Name $mod -Value $verStr -Force
                } else {
                    if ($null -eq $pkg.dependencies) { $pkg | Add-Member -MemberType NoteProperty -Name dependencies -Value ([PSCustomObject]@{}) }
                    $pkg.dependencies | Add-Member -MemberType NoteProperty -Name $mod -Value $verStr -Force
                }
                Write-Host "[NpmFix] ✅ Add '$mod@$verStr' to $(if ($isDev){'devDependencies'}else{'dependencies'}) in $pkgRelPath"
                $changed = $true
            }

            if ($changed) {
                $newContent = ($pkg | ConvertTo-Json -Depth 20)
                $pkgLines   = $pkgContent -split "`r?`n"
                $lastLine   = if ($pkgLines.Count -gt 0) { $pkgLines[-1] } else { '}' }
                $fixes.Add([PSCustomObject]@{
                    file_path    = $pkgRelPath
                    line_number  = $pkgLines.Count
                    title        = "Add missing npm module(s) to package.json: $($missingMods -join ', ')"
                    old_code     = $lastLine
                    new_code     = $lastLine
                    confidence   = 0.85
                    _fullContent = $newContent
                })
            }
        } catch { Write-Host "[NpmFix] package.json parse failed: $($_.Exception.Message)" }

        return $fixes
    }

    # ── PYTHON MISSING MODULE AUTO-FIX ──────────────────────────────────────────
    # Detects "ModuleNotFoundError: No module named 'X'" and "ImportError: No module
    # named 'X'" — Python runtime errors when a package is not in the environment.
    # Fix: add the module to requirements.txt (or Pipfile if that's what's used).
    # Heuristic:
    #  • Sub-package imports like 'google.cloud.bigquery' → map to package 'google-cloud-bigquery'
    #  • Standard library modules are excluded (os, sys, re, json, etc.)
    #  • Module names with underscores → try both 'name' and 'name' (pip accepts both)
    # Zero AI tokens — deterministic extraction.
    function Get-PythonModuleFixes {
        param([string]$logText)
        $fixes = [System.Collections.Generic.List[object]]::new()

        $missingPyMods = [System.Collections.Generic.List[string]]::new()
        $pyPatterns = @(
            "ModuleNotFoundError: No module named '([A-Za-z][^']*)'",
            "ImportError: No module named '([A-Za-z][^']*)'",
            "ImportError: cannot import name '([A-Za-z][^']*)' from '([A-Za-z][^']*)'",
            "from ([A-Za-z][^'\s]+) import.*ModuleNotFoundError",
            # ── command not found — pip package CLI removed from requirements ─
            'bundler: command not found: ([a-zA-Z][\w_-]+)',
            'sh: \d+: ([a-zA-Z][\w_-]+): not found',
            "command not found: ([a-zA-Z][\w_-]+)",
            'bash: ([a-zA-Z][\w_-]+): command not found'
        )
        $pyStdLib = @('os','sys','re','json','math','time','datetime','collections','itertools',
                      'functools','pathlib','typing','abc','io','copy','string','random',
                      'hashlib','hmac','base64','struct','socket','threading','multiprocessing',
                      'subprocess','shutil','tempfile','glob','fnmatch','logging','warnings',
                      'unittest','argparse','configparser','csv','sqlite3','http','urllib',
                      'email','html','xml','ast','dis','inspect','gc','weakref','contextlib',
                      'dataclasses','enum','uuid','platform','ctypes','signal','queue','array',
                      'bisect','heapq','decimal','fractions','statistics','textwrap','pprint',
                      'traceback','linecache','tokenize','token','keyword','operator','builtins')

        # ── Binary → pip package mapping ────────────────────────────────────
        # "command not found: pytest" → add 'pytest' to requirements.txt
        $binaryToPip = @{
            'pytest'     = 'pytest'
            'py.test'    = 'pytest'
            'gunicorn'   = 'gunicorn'
            'uvicorn'    = 'uvicorn'
            'celery'     = 'celery'
            'black'      = 'black'
            'isort'      = 'isort'
            'mypy'       = 'mypy'
            'pylint'     = 'pylint'
            'flake8'     = 'flake8'
            'coverage'   = 'coverage'
            'sphinx-build' = 'Sphinx'
            'sphinx'     = 'Sphinx'
            'alembic'    = 'alembic'
            'flask'      = 'Flask'
            'django'     = 'Django'
            'manage.py'  = 'Django'
            'pip'        = $null     # pip itself — skip
            'python'     = $null     # Python runtime — skip
            'python3'    = $null     # skip
            'pip3'       = $null     # skip
            'sh'         = $null     # skip
            'bash'       = $null     # skip
            'node'       = $null     # skip
        }

        $pyPkgMap = @{
            'cv2'='opencv-python'; 'PIL'='Pillow'; 'sklearn'='scikit-learn'
            'scipy'='scipy'; 'numpy'='numpy'; 'pandas'='pandas'
            'matplotlib'='matplotlib'; 'tensorflow'='tensorflow'; 'torch'='torch'
            'flask'='Flask'; 'django'='Django'; 'fastapi'='fastapi'
            'requests'='requests'; 'boto3'='boto3'; 'botocore'='botocore'
            'yaml'='PyYAML'; 'bs4'='beautifulsoup4'; 'lxml'='lxml'
            'paramiko'='paramiko'; 'cryptography'='cryptography'
            'psycopg2'='psycopg2-binary'; 'pymysql'='PyMySQL'
            'redis'='redis'; 'celery'='celery'; 'pydantic'='pydantic'
            'aiohttp'='aiohttp'; 'click'='click'; 'sqlalchemy'='SQLAlchemy'
            'alembic'='alembic'; 'dotenv'='python-dotenv'; 'google'='google-cloud'
            'azure'='azure-core'; 'msrest'='msrest'; 'jwt'='PyJWT'
            'Crypto'='pycryptodome'; 'pyotp'='pyotp'; 'stripe'='stripe'
            'twilio'='twilio'; 'sendgrid'='sendgrid'; 'openai'='openai'
            'anthropic'='anthropic'; 'langchain'='langchain'
        }

        foreach ($pat in $pyPatterns) {
            foreach ($m in [regex]::Matches($logText, $pat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $raw = ($m.Groups[2].Value -or $m.Groups[1].Value).Trim()
                # Resolve binary → pip package
                if ($binaryToPip.ContainsKey($raw)) {
                    $resolved = $binaryToPip[$raw]
                    if ($null -eq $resolved) { continue }
                    $raw = $resolved
                }
                $modTop = ($raw -split '\.')[0].Trim()
                if ([string]::IsNullOrWhiteSpace($modTop)) { continue }
                if ($pyStdLib -contains $modTop.ToLower()) { continue }
                if (-not $missingPyMods.Contains($modTop)) { $missingPyMods.Add($modTop) }
            }
        }

        if ($missingPyMods.Count -eq 0) { return $fixes }
        Write-Host "[PythonFix] Missing Python module(s): $($missingPyMods -join ', ')"

        $repoRoot = $env:BUILD_SOURCESDIRECTORY
        $reqFile = Get-ChildItem -Path $repoRoot -Filter 'requirements.txt' -Recurse -Depth 6 -EA SilentlyContinue |
                   Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|\.venv|venv|site-packages)[\\/]' } |
                   Select-Object -First 1
        if ($null -eq $reqFile) {
            $reqFile = Get-ChildItem -Path $repoRoot -Filter 'Pipfile' -Recurse -Depth 6 -EA SilentlyContinue |
                       Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|\.venv|venv)[\\/]' } |
                       Select-Object -First 1
        }
        if ($null -eq $reqFile) {
            Write-Host "[PythonFix] ⚠️ No requirements.txt or Pipfile found — cannot auto-fix."
            return $fixes
        }

        $reqRelPath = $reqFile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
        $reqContent = Get-Content $reqFile.FullName -Raw -EA SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($reqContent)) { $reqContent = "" }
        $reqLines = $reqContent -split "`r?`n"

        # ── Pipfile.lock / requirements version lookup ───────────────────────
        # When a package was previously installed, restore its exact version.
        # Pipfile.lock: { "default": { "requests": { "version": "==2.31.0" } } }
        # requirements.txt with pins: requests==2.31.0 (already in the file)
        $pyLockVersions = @{}
        $pipfileLock = Join-Path (Split-Path $reqFile.FullName) 'Pipfile.lock'
        if (Test-Path $pipfileLock) {
            try {
                $lockObj = Get-Content $pipfileLock -Raw | ConvertFrom-Json -Depth 10
                foreach ($section in @('default','develop')) {
                    if ($null -ne $lockObj.$section) {
                        foreach ($prop in $lockObj.$section.PSObject.Properties) {
                            $ver = $prop.Value.version
                            if ($ver) { $pyLockVersions[$prop.Name] = $ver }  # e.g. "==2.31.0"
                        }
                    }
                }
                Write-Host "[PythonFix] Read $($pyLockVersions.Count) version(s) from Pipfile.lock"
            } catch { Write-Host "[PythonFix] Could not parse Pipfile.lock" }
        }

        $toAdd = [System.Collections.Generic.List[string]]::new()
        foreach ($mod in $missingPyMods) {
            $pipName = if ($pyPkgMap.ContainsKey($mod)) { $pyPkgMap[$mod] } else { $mod }
            if ($reqContent -match "(?im)^$([regex]::Escape($pipName))(==|>=|<=|~=|>|<|\s|$)") {
                Write-Host "[PythonFix] '$pipName' already in $reqRelPath — skipping"
                continue
            }
            # Append version if found in Pipfile.lock; otherwise query PyPI
            $verSuffix = ''
            if ($pyLockVersions.ContainsKey($pipName)) {
                $verSuffix = $pyLockVersions[$pipName]   # e.g. "==2.31.0"
                Write-Host "[PythonFix] Using Pipfile.lock version: $pipName$verSuffix"
            } else {
                # No lock file entry — query PyPI for the latest stable release
                $apiVer = Get-LatestPipVersion -packageName $pipName
                if ($apiVer) { $verSuffix = $apiVer }
            }
            Write-Host "[PythonFix] ✅ Queuing fix: add '$pipName$verSuffix' to $reqRelPath"
            $toAdd.Add("$pipName$verSuffix")
        }

        if ($toAdd.Count -gt 0) {
            $newContent = ($reqLines + @($toAdd)) -join "`n"
            $lastLine   = if ($reqLines.Count -gt 0) { $reqLines[-1] } else { '' }
            $fixes.Add([PSCustomObject]@{
                file_path    = $reqRelPath
                line_number  = $reqLines.Count + 1
                title        = "Add missing Python module(s) to $($reqFile.Name): $($toAdd -join ', ')"
                old_code     = $lastLine
                new_code     = $lastLine + "`n" + ($toAdd -join "`n")
                confidence   = 0.88
                _fullContent = $newContent
            })
        }
        return $fixes
    }

    # ── RUBY / BUNDLER VERSION MISMATCH AUTO-FIX ────────────────────────────────
    # Two separate but related errors:
    #  1. "Your Ruby version is X, but your Gemfile specified Y"
    #     → Fix: update .ruby-version file (if present) OR remove/update the
    #       `ruby 'Y.Y.Y'` constraint in the Gemfile to match the agent's Ruby
    #  2. "Could not find 'bundler' (X.X.X) required by your Gemfile.lock"
    #     → Fix: add FORCED_BUNDLER_VERSION export to the pipeline step that
    #       runs bundle install, OR update the BUNDLER_VERSION variable
    #  These are MANUAL TODOS — the system annotates the exact file + line
    #  and tells the developer exactly what to change. No guessing.
    function Get-RubyVersionFixes {
        param([string]$logText)
        $fixes = [System.Collections.Generic.List[object]]::new()

        $repoRoot = $env:BUILD_SOURCESDIRECTORY

        # ── Pattern 1: Ruby version mismatch ─────────────────────────────────
        if ($logText -match "Your Ruby version is ([\d.]+), but your Gemfile specified ([\d.]+)") {
            $agentRuby  = $matches[1]; $gemfileRuby = $matches[2]
            Write-Host "[RubyVersionFix] Agent Ruby $agentRuby ≠ Gemfile ruby '$gemfileRuby'"

            # Fix .ruby-version if it exists
            $rvFile = Get-ChildItem -Path $repoRoot -Filter '.ruby-version' -Recurse -Depth 6 -EA SilentlyContinue |
                      Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|vendor)[\\/]' } |
                      Select-Object -First 1

            if ($null -ne $rvFile) {
                $rvRelPath = $rvFile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
                $rvContent = (Get-Content $rvFile.FullName -Raw -EA SilentlyContinue).Trim()
                $fixes.Add([PSCustomObject]@{
                    file_path    = $rvRelPath
                    line_number  = 1
                    title        = "Update .ruby-version from $rvContent to $agentRuby (CI agent Ruby version mismatch)"
                    old_code     = $rvContent
                    new_code     = $agentRuby
                    confidence   = 0.92
                    _fullContent = $agentRuby + "`n"
                })
            }

            # Also scan Gemfile for `ruby 'X.X.X'` constraint
            $gemFile = Get-ChildItem -Path $repoRoot -Filter 'Gemfile' -Recurse -Depth 8 -EA SilentlyContinue |
                       Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|vendor|\.gems|Pods)[\\/]' } |
                       Select-Object -First 1
            if ($null -ne $gemFile) {
                $gemRelPath = $gemFile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
                $gemContent = Get-Content $gemFile.FullName -Raw -EA SilentlyContinue
                if ($gemContent -match "(ruby\s+'$([regex]::Escape($gemfileRuby))')") {
                    $oldLine  = $matches[1]
                    $newLine  = "ruby '$agentRuby'"
                    $gemLines = $gemContent -split "`r?`n"
                    $lineIdx  = 0
                    for ($gi = 0; $gi -lt $gemLines.Count; $gi++) {
                        if ($gemLines[$gi] -match [regex]::Escape($oldLine)) { $lineIdx = $gi + 1; break }
                    }
                    if ($lineIdx -gt 0) {
                        $fixes.Add([PSCustomObject]@{
                            file_path   = $gemRelPath
                            line_number = $lineIdx
                            title       = "Update Gemfile ruby constraint from '$gemfileRuby' to '$agentRuby' (Ruby version mismatch)"
                            old_code    = $oldLine
                            new_code    = $newLine
                            confidence  = 0.88
                        })
                    }
                }
            }
        }

        # ── Pattern 2: Bundler version constraint ─────────────────────────────
        if ($logText -match "Could not find 'bundler' \(([\d.]+)\) required by your Gemfile\.lock") {
            $reqBundler = $matches[1]
            Write-Host "[RubyVersionFix] Bundler version $reqBundler required by Gemfile.lock"
            # Generate a TODO: update BUNDLER_VERSION in the pipeline or install the version
            $fixes.Add([PSCustomObject]@{
                file_path   = 'INSERT_MANUAL_VALUE_HERE'
                line_number = 0
                title       = "⚠️ MANUAL ACTION REQUIRED: Install bundler version $reqBundler — add 'gem install bundler:$reqBundler' step to pipeline, or update BUNDLER_VERSION variable"
                old_code    = "BUNDLER_VERSION=<current>"
                new_code    = "BUNDLER_VERSION=$reqBundler"
                confidence  = 0.80
            })
        }

        return $fixes
    }

    # ── MAKEFILE TAB-INDENTATION AUTO-FIX ───────────────────────────────────────
    # The GNU make "missing separator" error fires when a recipe line uses SPACES
    # instead of TABs. The fix is pure text replacement: swap leading spaces → tab.
    # This is the #1 cause of Makefile failures when Windows developers edit on
    # macOS/Linux CI agents (their editors silently convert tabs to spaces).
    # Zero AI tokens, zero hallucination — purely deterministic.
    function Get-MakefileFixes {
        param([string]$logText)
        $fixes = [System.Collections.Generic.List[object]]::new()

        if ($logText -notmatch '(?i)(missing separator|Makefile.*expected separator|makefile.*missing tab|make.*\*\*\*.*missing separator)') {
            return $fixes
        }

        $repoRoot = $env:BUILD_SOURCESDIRECTORY
        $mkFile = Get-ChildItem -Path $repoRoot -Recurse -Depth 8 -EA SilentlyContinue |
                  Where-Object { $_.Name -eq 'Makefile' -or $_.Name -match '\.mk$' } |
                  Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|vendor|build)[\\/]' } |
                  Select-Object -First 1

        if ($null -eq $mkFile) { return $fixes }

        $mkRelPath = $mkFile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
        $mkContent = Get-Content $mkFile.FullName -Raw -EA SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($mkContent)) { return $fixes }

        $mkLines     = $mkContent -split "`r?`n"
        $fixedLines  = [string[]]::new($mkLines.Count)
        $afterTarget = $false; $fixCount = 0

        for ($mi = 0; $mi -lt $mkLines.Count; $mi++) {
            $ml = $mkLines[$mi]
            $fixedLines[$mi] = $ml

            if ([string]::IsNullOrWhiteSpace($ml) -or $ml.TrimStart().StartsWith('#')) {
                $afterTarget = $false; continue
            }
            if ($ml -match '^[^\s#%@].*:') { $afterTarget = $true; continue }
            if ($afterTarget -and $ml -match '^( +)') {
                $fixedLines[$mi] = "`t" + $ml.TrimStart()
                $fixCount++
            }
        }

        if ($fixCount -gt 0) {
            $newContent = $fixedLines -join "`n"
            $lastLine   = $mkLines[-1]
            Write-Host "[MakefileFix] ✅ Fixing $fixCount recipe line(s) with spaces → TAB in $mkRelPath"
            $fixes.Add([PSCustomObject]@{
                file_path    = $mkRelPath
                line_number  = 1
                title        = "Fix Makefile recipe indentation: replace spaces with TAB ($fixCount line(s) — GNU make 'missing separator' fix)"
                old_code     = "(recipe lines with leading spaces)"
                new_code     = "(recipe lines with leading TAB)"
                confidence   = 0.97
                _fullContent = $newContent
            })
        }

        return $fixes
    }

    # ── GRADLE DEPENDENCY AUTO-FIX ──────────────────────────────────────────────
    # The #1 Android CI failure: "Could not resolve X:Y:Z" — a Gradle dependency
    # that doesn't exist in any declared repository, or a version that was yanked.
    # Detects the failing dependency notation and adds it to the correct block in
    # build.gradle (Groovy) or build.gradle.kts (Kotlin DSL).
    #
    # Also handles:
    #   "Failed to resolve: groupId:artifactId:version"
    #   "Unable to resolve dependency for ':app@debug/compileClasspath'"
    #   "Could not find groupId:artifactId:version"
    #
    # Strategy: find the app-module build.gradle (prefers app/ over root), parse the
    # existing dependencies{} block, and append the missing dependency as 'implementation'.
    # Uses _fullContent so the remediator rewrites the whole file cleanly.
    function Get-GradleDependencyFixes {
        param([string]$logText)
        $fixes = [System.Collections.Generic.List[object]]::new()

        # Extract failing dependency notations from error messages
        $missingDeps = [System.Collections.Generic.List[string]]::new()
        $gradlePatterns = @(
            "Could not resolve ([\w.\-]+:[\w.\-]+:[\w.\-]+)",
            "Failed to resolve: ([\w.\-]+:[\w.\-]+:[\w.\-]+)",
            "Could not find ([\w.\-]+:[\w.\-]+:[\w.\-]+)",
            "Unable to resolve dependency.*'([\w.\-]+:[\w.\-]+:[\w.\-]+)'",
            "No cached version.*for ([\w.\-]+:[\w.\-]+:[\w.\-]+)"
        )
        foreach ($pat in $gradlePatterns) {
            foreach ($m in [regex]::Matches($logText, $pat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $dep = $m.Groups[1].Value.Trim()
                if ($dep -and -not $missingDeps.Contains($dep)) { $missingDeps.Add($dep) }
            }
        }

        if ($missingDeps.Count -eq 0) { return $fixes }
        Write-Host "[GradleFix] Missing Gradle dependency(ies): $($missingDeps -join ', ')"

        $repoRoot = $env:BUILD_SOURCESDIRECTORY

        # Prefer app/build.gradle over root build.gradle
        $gradleFile = Get-ChildItem -Path (Join-Path $repoRoot 'app') -Filter 'build.gradle*' -EA SilentlyContinue |
                      Select-Object -First 1
        if ($null -eq $gradleFile) {
            $gradleFile = Get-ChildItem -Path $repoRoot -Filter 'build.gradle*' -Recurse -Depth 4 -EA SilentlyContinue |
                          Where-Object { $_.FullName -notmatch '[\\/](\.git|build|cache|wrapper)[\\/]' } |
                          Select-Object -First 1
        }
        if ($null -eq $gradleFile) {
            Write-Host "[GradleFix] ⚠️ No build.gradle found — cannot auto-fix."
            return $fixes
        }

        $isKts    = $gradleFile.Name -like '*.kts'
        $relPath  = $gradleFile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
        $content  = Get-Content $gradleFile.FullName -Raw -EA SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($content)) { return $fixes }

        # ── libs.versions.toml version catalog lookup ────────────────────────
        # Modern Android projects declare dependencies in Gradle version catalogs.
        # When a dependency is re-added, check the catalog for the pinned version
        # so the restored dependency uses the same version as before.
        # libs.versions.toml format:  firebase-bom = "32.1.0"
        $catalogVersions = @{}
        $catalogPath = Get-ChildItem -Path $repoRoot -Filter 'libs.versions.toml' -Recurse -Depth 6 -EA SilentlyContinue |
                       Select-Object -First 1
        if ($null -ne $catalogPath) {
            $catalogText = Get-Content $catalogPath.FullName -Raw -EA SilentlyContinue
            foreach ($lm in [regex]::Matches($catalogText, '^([\w-]+)\s*=\s*"([^"]+)"', [System.Text.RegularExpressions.RegexOptions]::Multiline)) {
                $catalogVersions[$lm.Groups[1].Value] = $lm.Groups[2].Value
            }
            Write-Host "[GradleFix] Read $($catalogVersions.Count) version(s) from libs.versions.toml"
        }

        $changed  = $false
        $newContent = $content

        foreach ($dep in $missingDeps) {
            if ($content -match [regex]::Escape($dep)) {
                Write-Host "[GradleFix] '$dep' already in $relPath — skipping"
                continue
            }

            # Try to find version from catalog (match groupId:artifactId to catalog key)
            $parts    = $dep -split ':'
            $artifact = if ($parts.Count -ge 2) { $parts[1] } else { $dep }
            $catKey   = ($artifact -replace '[-_]','[-_]').ToLower()
            $catVer   = $catalogVersions.Keys | Where-Object { $_ -replace '[-_]','' -like "*$($catKey -replace '[-_]','')*" } | Select-Object -First 1
            $resolvedDep = $dep
            if ($catVer -and $parts.Count -ge 2 -and $parts.Count -lt 3) {
                $resolvedDep = "$dep`:$($catalogVersions[$catVer])"
                Write-Host "[GradleFix] Found version from catalog for '$artifact': $($catalogVersions[$catVer])"
            } elseif ($parts.Count -ge 2 -and $parts.Count -lt 3) {
                # No catalog entry — query Maven Central for the latest stable version
                $mvnVer = Get-LatestMavenVersion -groupId $parts[0] -artifactId $parts[1]
                if ($mvnVer) {
                    $resolvedDep = "$dep`:$mvnVer"
                    Write-Host "[GradleFix] Found Maven Central version for '$($parts[0])`:$($parts[1])': $mvnVer"
                }
            }

            Write-Host "[GradleFix] ✅ Queuing fix: add '$resolvedDep' to $relPath"
            $depLine = if ($isKts) { "    implementation(`"$resolvedDep`")" } else { "    implementation '$resolvedDep'" }

            if ($newContent -match "(?s)dependencies\s*\{") {
                $newContent = [regex]::Replace($newContent, "(?s)(dependencies\s*\{)", "`$1`n$depLine")
            } else {
                $newContent = $newContent.TrimEnd() + "`n`ndependencies {`n$depLine`n}`n"
            }
            $changed = $true
        }

        if ($changed) {
            $lastLine = ($content -split "`r?`n")[-1]
            $fixes.Add([PSCustomObject]@{
                file_path    = $relPath
                line_number  = ($content -split "`r?`n").Count
                title        = "Add missing Gradle dependency(ies) to $($gradleFile.Name): $($missingDeps -join ', ')"
                old_code     = $lastLine
                new_code     = $lastLine
                confidence   = 0.88
                _fullContent = $newContent
            })
        }

        return $fixes
    }
    # Walks from the source file's directory up to the repo root looking for
    # the language-appropriate dependency file. Returns the RELATIVE path
    # so it can become a fix entry just like any other file fix.
    # Covers: Python (requirements.txt/Pipfile/pyproject.toml), JS/TS
    # (package.json), Ruby (Gemfile), Go (go.mod), PHP (composer.json),
    # Java/Kotlin (build.gradle / pom.xml), Swift (Package.swift).
    # ── SWIFT PACKAGE MANAGER AUTO-FIX ──────────────────────────────────────
    # Detects SPM dependency resolution failures and suggests the correct
    # package declaration to add to Package.swift.
    # Common failures: private repo auth, version constraint conflicts,
    # checksum mismatches after a package was yanked/re-tagged.
    function Get-SwiftPackageFixes {
        param([string]$logText)
        $fixes = [System.Collections.Generic.List[object]]::new()

        $spmPatterns = @(
            'error: no such module.*import',
            "could not resolve package dependencies",
            'error: product.*not found in package',
            'error: package.*not found',
            "xcodebuild: error: Could not resolve package",
            'The package at .* cannot be accessed',
            'dependency.*https://github.com.*not found',
            'requirement.*version.*not found.*package'
        )
        $isSpmError = $spmPatterns | Where-Object { $logText -match $_ }
        if (-not $isSpmError) { return $fixes }

        $repoRoot = $env:BUILD_SOURCESDIRECTORY
        $pkgSwift = Get-ChildItem -Path $repoRoot -Filter 'Package.swift' -Recurse -Depth 4 -EA SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '[\\/](\.git|\.build|checkouts|build)[\\/]' } |
                    Select-Object -First 1

        if ($null -eq $pkgSwift) {
            Write-Host "[SPMFix] ℹ️ No Package.swift found — project uses CocoaPods or Carthage instead"
            return $fixes
        }

        Write-Host "[SPMFix] Found Package.swift at $($pkgSwift.FullName)"

        # Extract the missing package URL from the error if possible
        $missingPkg = $null
        if ($logText -match 'https://github\.com/[\w\-\.]+/[\w\-\.]+') {
            $missingPkg = $matches[0]
        }

        $content = Get-Content $pkgSwift.FullName -Raw -EA SilentlyContinue
        $relPath  = $pkgSwift.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')

        if ($missingPkg -and $content -notmatch [regex]::Escape($missingPkg)) {
            # Add the missing package to Package.swift dependencies array
            $newDep  = "        .package(url: `"$missingPkg`", from: `"1.0.0`"),"
            if ($content -match '(?s)(dependencies:\s*\[)') {
                $newContent = $content -replace '(?s)(dependencies:\s*\[)', "`$1`n$newDep"
                $fixes.Add([PSCustomObject]@{
                    file_path    = $relPath
                    line_number  = 1
                    title        = "Add missing Swift Package dependency: $missingPkg"
                    old_code     = "dependencies: ["
                    new_code     = "dependencies: [`n$newDep"
                    confidence   = 0.75
                    _fullContent = $newContent
                })
                Write-Host "[SPMFix] ✅ Queued: add $missingPkg to Package.swift"
            }
        } else {
            # SPM error but can't auto-fix — generate TODO fix with guidance
            $fixes.Add([PSCustomObject]@{
                file_path    = $relPath
                line_number  = 1
                title        = "MANUAL ACTION: Resolve Swift Package Manager dependency failure"
                old_code     = "# Package.swift dependencies"
                new_code     = "# Package.swift dependencies"
                confidence   = 0.0
                _fullContent = $null
            })
            Write-Host "[SPMFix] ⚠️ SPM error detected — manual review needed for Package.swift"
        }
        return $fixes
    }

    # ── CARTHAGE AUTO-FIX ────────────────────────────────────────────────────
    # Carthage + Xcode 12+ requires --use-xcframeworks. Detects the classic
    # "Dependency X1.0 has no shared framework schemes" and similar failures.
    function Get-CarthageFixes {
        param([string]$logText)
        $fixes = [System.Collections.Generic.List[object]]::new()

        $carthagePatterns = @(
            'CarthageKit\.CarthageError',
            'Build Failed.*carthage',
            'has no shared framework schemes',
            'Carthage.*Build Failed',
            'archive.*carthage.*failed',
            'dependency.*not.*found.*Cartfile',
            'Cartfile\.resolved.*conflict'
        )
        $isCarthageError = $carthagePatterns | Where-Object { $logText -match $_ }
        if (-not $isCarthageError) { return $fixes }

        $repoRoot  = $env:BUILD_SOURCESDIRECTORY
        $cartfile  = Get-ChildItem -Path $repoRoot -Filter 'Cartfile' -Recurse -Depth 4 -EA SilentlyContinue |
                     Where-Object { $_.FullName -notmatch '[\\/](\.git|Carthage|build)[\\/]' } |
                     Select-Object -First 1

        if ($null -eq $cartfile) { return $fixes }
        $relPath   = $cartfile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
        Write-Host "[CarthageFix] Found Cartfile at $relPath"

        # Check if Fastfile uses carthage without --use-xcframeworks (Xcode 12+ requirement)
        $fastfile  = Get-ChildItem -Path $repoRoot -Filter 'Fastfile' -Recurse -Depth 6 -EA SilentlyContinue |
                     Select-Object -First 1
        if ($null -ne $fastfile) {
            $fContent = Get-Content $fastfile.FullName -Raw -EA SilentlyContinue
            if ($fContent -match 'carthage\(' -and $fContent -notmatch 'use_xcframeworks.*true') {
                $ffRelPath = $fastfile.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
                $newContent = $fContent -replace '(carthage\([^)]*?)(platform:)', '$1use_xcframeworks: true, $2'
                if ($newContent -ne $fContent) {
                    $fixes.Add([PSCustomObject]@{
                        file_path    = $ffRelPath
                        line_number  = ($fContent -split "\r?\n" | Select-String 'carthage(' | Select-Object -First 1 -ExpandProperty LineNumber) + 0
                        title        = "Add use_xcframeworks: true to carthage() call (required for Xcode 12+)"
                        old_code     = "carthage(..."
                        new_code     = "carthage(use_xcframeworks: true, ...)"
                        confidence   = 0.85
                        _fullContent = $newContent
                    })
                    Write-Host "[CarthageFix] ✅ Queued: add use_xcframeworks: true to Fastfile"
                }
            }
        }
        return $fixes
    }

    # ── XCODE SCHEME / WORKSPACE NOT FOUND FIX ──────────────────────────────
    # "xcodebuild: error: scheme X not found" or workspace/project not found.
    # Lists all available schemes from the discovered workspace/project and
    # generates a MANUAL ACTION fix with the correct scheme names.
    function Get-XcodeSchemeFixes {
        param([string]$logText)
        $fixes = [System.Collections.Generic.List[object]]::new()

        if ($logText -notmatch "scheme.*not found|workspace.*not found|project.*not found.*xcodebuild|does not contain a scheme") { return $fixes }

        # Extract the scheme name that was not found
        $badScheme = $null
        if ($logText -match "scheme '([^']+)' not found") { $badScheme = $matches[1] }

        $repoRoot = $env:BUILD_SOURCESDIRECTORY
        $xcworkspace = Get-ChildItem -Path $repoRoot -Filter '*.xcworkspace' -Recurse -Depth 6 -EA SilentlyContinue |
                       Where-Object { $_.FullName -notmatch '[\\/](\.git|Carthage|Pods|DerivedData|\.build)[\\/]' } |
                       Select-Object -First 1

        $xcproject = Get-ChildItem -Path $repoRoot -Filter '*.xcodeproj' -Recurse -Depth 6 -EA SilentlyContinue |
                     Where-Object { $_.FullName -notmatch '[\\/](\.git|Carthage|Pods|DerivedData)[\\/]' } |
                     Select-Object -First 1

        $target = if ($xcworkspace) { $xcworkspace } elseif ($xcproject) { $xcproject } else { $null }
        if ($null -eq $target) { return $fixes }

        # List available schemes using xcodebuild -list
        $availableSchemes = @()
        try {
            $flag = if ($xcworkspace) { '-workspace' } else { '-project' }
            $out = xcodebuild $flag $target.FullName -list 2>&1
            $inSchemes = $false
            foreach ($line in ($out -split "\r?\n")) {
                $lt = $line.Trim()
                if ($lt -match '^Schemes?:') { $inSchemes = $true; continue }
                if ($inSchemes -and $lt -eq '') { $inSchemes = $false; continue }
                if ($inSchemes -and $lt) { $availableSchemes += $lt }
            }
        } catch { }

        $relPath = $target.FullName.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
        $schemeList = if ($availableSchemes) { $availableSchemes -join ', ' } else { '(run: xcodebuild -list to see schemes)' }

        $fixes.Add([PSCustomObject]@{
            file_path    = $relPath
            line_number  = 1
            title        = "MANUAL ACTION: Xcode scheme$(if($badScheme){" '$badScheme'"}) not found — available: $schemeList"
            old_code     = "scheme: '$badScheme'"
            new_code     = "# Available schemes: $schemeList"
            confidence   = 0.0
            _fullContent = $null
        })
        Write-Host "[XcodeSchemeFix] ⚠️ Scheme not found. Available: $schemeList"
        return $fixes
    }

    function Find-DependencyFile {
        param([string]$sourcePath, [string]$lang, [string]$repoRoot)
        $depFiles = @{
            'python'     = @('requirements.txt','Pipfile','pyproject.toml','setup.cfg')
            'javascript' = @('package.json')
            'typescript' = @('package.json')
            'ruby'       = @('Gemfile')
            'go'         = @('go.mod')
            'php'        = @('composer.json')
            'kotlin'     = @('build.gradle','build.gradle.kts','pom.xml')
            'java'       = @('pom.xml','build.gradle')
            'csharp'     = @('*.csproj','*.sln','Directory.Packages.props')
            'swift'      = @('Package.swift','Podfile')
        }
        $targets = if ($depFiles.ContainsKey($lang)) { $depFiles[$lang] } else { return $null }
        # Walk up from source file's directory to repo root
        $dir = [System.IO.Path]::GetDirectoryName((Join-Path $repoRoot $sourcePath))
        while ($dir.StartsWith($repoRoot) -or $dir -eq $repoRoot) {
            foreach ($target in $targets) {
                if ($target -match '\*') {
                    $hit = Get-ChildItem -Path $dir -Filter $target -EA SilentlyContinue | Select-Object -First 1
                    if ($null -ne $hit) { return $hit.FullName.Replace($repoRoot,'').TrimStart('/\').Replace('\','/') }
                } else {
                    $full = Join-Path $dir $target
                    if (Test-Path $full) { return $full.Replace($repoRoot,'').TrimStart('/\').Replace('\','/') }
                }
            }
            $parent = [System.IO.Path]::GetDirectoryName($dir)
            if ($parent -eq $dir) { break }   # reached filesystem root
            $dir = $parent
        }
        return $null  # not found
    }

    # ── PACKAGE DEPENDENCY FIX GENERATOR ─────────────────────────────────
    # Given the dependency file content and the package/symbol to add,
    # generates a fix that appends the package to the correct location.
    # Also runs a quick install-to-verify on the agent so the PR only
    # includes packages that actually EXIST in the registry (PyPI, npm, etc.).
    function New-PackageDependencyFix {
        param(
            [string]$depFilePath,   # relative repo path
            [string]$depFileContent,
            [string]$symbol,        # the import symbol e.g. 'requests'
            [string]$lang,
            [string]$repoRoot
        )

        # ── Step 1: verify package exists by attempting a quick install ───
        # This runs on the triage agent (ephemeral). It does NOT affect prod.
        # It confirms the package name is valid before we propose a PR fix.
        $pkgName = $symbol   # default: import name often matches package name
        $verified = $false

        $oldEA = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        switch ($lang) {
            'python' {
                # pip install --dry-run checks PyPI without writing to disk
                $out = pip install --dry-run $pkgName 2>&1
                if ($LASTEXITCODE -eq 0) { $verified = $true }
                else {
                    # Some packages have different install names (PIL→Pillow, cv2→opencv-python)
                    $knownAliases = @{
                        'PIL'='Pillow'; 'cv2'='opencv-python'; 'sklearn'='scikit-learn'
                        'bs4'='beautifulsoup4'; 'yaml'='PyYAML'; 'dotenv'='python-dotenv'
                        'Crypto'='pycryptodome'; 'gi'='PyGObject'; 'usb'='pyusb'
                    }
                    if ($knownAliases.ContainsKey($symbol)) {
                        $pkgName = $knownAliases[$symbol]
                        $out2 = pip install --dry-run $pkgName 2>&1
                        if ($LASTEXITCODE -eq 0) { $verified = $true }
                    }
                }
            }
            'javascript' {
                $out = npm show $pkgName version 2>&1
                if ($LASTEXITCODE -eq 0) { $verified = $true }
            }
            'typescript' {
                $out = npm show $pkgName version 2>&1
                if ($LASTEXITCODE -eq 0) { $verified = $true }
            }
            'ruby' {
                $out = gem search $pkgName --no-verbose 2>&1
                if ($LASTEXITCODE -eq 0 -and "$out" -match [regex]::Escape($pkgName)) { $verified = $true }
            }
            'go' {
                # Go packages are URLs — symbol may already be a path; skip dry-run verification
                $verified = $true
            }
            'php' {
                $out = composer show $pkgName 2>&1
                if ($LASTEXITCODE -eq 0) { $verified = $true }
            }
            default { $verified = $true }   # java/kotlin/csharp — build tool handles
        }
        $ErrorActionPreference = $oldEA

        if (-not $verified) {
            Write-Host "  ⚠️  Package '$pkgName' not found in registry — skipping dependency fix. Developer must install manually."
            return $null
        }
        Write-Host "  ✅ Package '$pkgName' verified in registry."

        # ── Step 2: check if package already in dependency file ───────────
        if ($depFileContent -match [regex]::Escape($pkgName)) {
            Write-Host "  ℹ️  '$pkgName' already listed in $depFilePath — no dependency fix needed."
            return $null
        }

        # ── Step 3: generate the fix for the dependency file ───────────────
        $lines = $depFileContent -split "`n"
        $oldLastLine = $lines[-1]
        switch ($lang) {
            'python' {
                if ($depFilePath -match 'pyproject.toml') {
                    # Add under [project] dependencies = [ ]
                    $newContent = $depFileContent -replace '(?m)(dependencies\s*=\s*\[)', "`$1`n    `"$pkgName`","
                } elseif ($depFilePath -match 'Pipfile') {
                    $newContent = $depFileContent -replace '(?m)(\[packages\])', "`$1`n$pkgName = `"*`""
                } else {
                    # requirements.txt — append at end
                    $newLastLine = ($oldLastLine.Trim() -eq '') ? $pkgName : "$oldLastLine`n$pkgName"
                    $newContent = ($lines[0..($lines.Count-2)] + @($newLastLine)) -join "`n"
                }
            }
            'javascript' {
                # Add to dependencies in package.json
                $newContent = $depFileContent -replace '("dependencies"\s*:\s*\{)', "`$1`n    `"$pkgName`": `"*`","
            }
            'typescript' {
                # Add to dependencies in package.json (same as javascript)
                $newContent = $depFileContent -replace '("dependencies"\s*:\s*\{)', "`$1`n    `"$pkgName`": `"*`","
            }
            'ruby' {
                # Add gem to Gemfile
                $newContent = $depFileContent + "`ngem '$pkgName'"
            }
            'go' {
                # go.mod: add require entry
                $newContent = $depFileContent -replace '(?m)(^require\s*\()', "`$1`n`t$pkgName v0.0.0"
            }
            'php' {
                $json = $depFileContent | ConvertFrom-Json -EA SilentlyContinue
                if ($null -ne $json) {
                    if ($null -eq $json.require) { $json | Add-Member -NotePropertyName require -NotePropertyValue @{} }
                    $json.require | Add-Member -NotePropertyName $pkgName -NotePropertyValue '*' -Force
                    $newContent = $json | ConvertTo-Json -Depth 10
                } else { $newContent = $depFileContent }
            }
            default { return $null }
        }

        if ($newContent -eq $depFileContent) { return $null }

        return [PSCustomObject]@{
            file_path   = $depFilePath
            line_number = $lines.Count
            title       = "Add missing package '$pkgName' to $([System.IO.Path]::GetFileName($depFilePath))"
            old_code    = $oldLastLine
            new_code    = ($newContent -split "`n")[-1]
            confidence  = if ($verified) { 1.0 } else { 0.6 }
            # Store full new content so remediator can write entire file
            _fullContent = $newContent
        }
    }

    # Detect programming language from file extension for use in AI prompt
    function Get-LanguageLabel {
        param([string]$path)
        $ext = [System.IO.Path]::GetExtension($path).ToLower()
        $name = [System.IO.Path]::GetFileName($path)
        $map = @{
            '.java'='Java'; '.kt'='Kotlin'; '.kts'='Kotlin'; '.cs'='C#'; '.vb'='VB.NET'
            '.fs'='F#'; '.swift'='Swift'; '.go'='Go'; '.rs'='Rust'; '.php'='PHP'
            '.py'='Python'; '.js'='JavaScript'; '.ts'='TypeScript'; '.tsx'='TypeScript/React'
            '.jsx'='JavaScript/React'; '.rb'='Ruby'; '.sh'='Bash'; '.ps1'='PowerShell'
            '.tf'='Terraform HCL'; '.groovy'='Groovy'; '.json'='JSON'; '.xml'='XML'
            '.yaml'='YAML'; '.yml'='YAML'; '.toml'='TOML'; '.csproj'='MSBuild XML'
            '.html'='HTML'; '.htm'='HTML'; '.css'='CSS'; '.scss'='SCSS'; '.less'='LESS'; '.sass'='Sass'; '.sql'='SQL'; '.vue'='Vue SFC'
        }
        if ($map.ContainsKey($ext)) { return $map[$ext] }
        if ($name -in @('Fastfile','Gemfile')) { return 'Ruby' }
        if ($name -match 'Dockerfile') { return 'Dockerfile' }
        if ($name -match 'Jenkinsfile') { return 'Groovy' }
        if ($name -match '\.plist$|\.xcconfig$') { return 'XML/Plist' }
        return 'unknown'
    }

    # ──────────────────────────────────────────────────────────────────
    # Acts like a developer reviewing the whole file: finds EVERY syntax
    # issue, not just what the parser happened to surface first. Returns
    # an array of fixes; each is validated by the parser before being kept.
    # ── AZURE OPENAI — RESPONSES API ─────────────────────────────────────
    # Endpoint: https://subway-devops-ai.services.ai.azure.com/openai/v1/responses
    # Auth:     api-key header (AZURE_OPENAI_KEY ADO secret variable)
    # Model:    configurable via AZURE_OPENAI_DEPLOYMENT (default: gpt-5)

    # ── CROSS-RUN FIX MEMORY (helpers) ────────────────────────────────────
    # Stable, file-INDEPENDENT signature: same error in any file/commit/repo maps
    # to the same key. Volatile bits (line numbers, paths) are normalized out so a
    # recurring error reuses a previously-validated fix instead of paying for AI again.
    function Get-ErrorSignature {
        param([string]$lang, [string]$message)
        $m = "$message".ToLower()
        $m = $m -replace '\d+', 'N'            # collapse line/col numbers
        $m = $m -replace '/[^\s:]+', '/PATH'   # collapse absolute paths
        $m = ($m -replace '\s+', ' ').Trim()
        if ($m.Length -gt 120) { $m = $m.Substring(0,120) }
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$lang|$m"))
        $sha.Dispose()
        return (-join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') }))
    }
    # Serve a remembered fix ONLY if it hasn't failed twice (eviction cap). A served
    # fix still flows through the normal apply + parser-validate path, so a stale hit
    # is harmless — it just gets rejected and the loop falls through to the AI.
    function Serve-FixMemory {
        param([string]$sig)
        if ($null -ne $script:fixMemory -and $script:fixMemory.ContainsKey($sig)) {
            $e = $script:fixMemory[$sig]
            if ([int]$e.fails -lt 2) { return $e.fixes }
        }
        return $null
    }

    function Get-AIFixes {
        param([string]$filePath, [string]$numberedContent, [string]$parserError, [int]$errorLine, [string]$priorVersion)

        # Tell the AI exactly which language it's reviewing so it applies
        # language-appropriate fixes (e.g. Java needs ';', Python uses indent).
        $langLabel = Get-LanguageLabel -path $filePath

        $rules = @(
            "You are a senior $langLabel developer AND mobile CI/CD engineer specialising in iOS/Android Azure DevOps pipelines.",
            'The parser / build tool reported an error below. Your job is NOT just to fix that one line.',
            "Scan EVERY line of this $langLabel file and find ALL syntax issues: unclosed quotes, missing",
            'braces, wrong operators, mismatched parens, missing semicolons (if required by the language).',
            'Return fixes for ALL of them as an array.',
            '',
            'RULES:',
            '1. Fix the reported error AND any other syntax issues visible in the file.',
            '2. For EOF / unexpected-token / missing-semicolon errors: an EARLIER line is the real',
            '   cause. Scan UPWARD from the error AND the whole file — there may be multiple issues.',
            '3. Return each fix as LINE NUMBER (from the prefix shown) + full corrected line in new_code',
            '   (without the line-number prefix). Preserve original indentation exactly.',
            '4. For variable name typos: rename ONLY the mistyped identifier, nothing else.',
            '5. For ADO pipeline variable macros like $(Build.SourcesDirectory) or $(System.X): NEVER change them.',
            '   These are Azure DevOps pipeline macros expanded at runtime — they are NOT bash command substitutions.',
            '6. Never modify YAML pipeline structure keys (steps:, jobs:, task:, displayName:, inputs:).',
            '7. Never invent changes to lines that have no syntax error.',
            '8. For any [REDACTED_*] placeholder: write "# TODO: INSERT_ACTUAL_VALUE_HERE".',
            '9. Use the PRIOR WORKING VERSION (if provided) to understand the intended correct form.',
            '10. Output RAW JSON only. No markdown fences. The fixes field MUST be an array.',
            '',
            'MOBILE CI/CD CONTEXT (apply this knowledge when diagnosing):',
            '- iOS Fastlane scripts: shell scripts embedded in YAML blocks. Common errors:',
            '    unclosed echo "...($(cmd)) — close ) then "',
            '    VAR=$(cmd "arg — close " then ) — the ) INSIDE "..." does NOT close $(',
            '    ADO macros $(Build.X) inside "..." strings are already valid — DO NOT change them',
            '    ${BUNDLER_VERSION} ${RUBY_VERSION} — bash var expansions, always need closing }',
            '- Android Gradle (.gradle / .kts): missing semicolons, unclosed braces in dependencies{}',
            '    build.gradle: versionCode and versionName must be integers/strings respectively',
            '    Kotlin DSL (.kts): lambdas need -> and closing braces match',
            '- Ruby / Fastfile: lane(:name) { } blocks, options hash commas, string interpolation #{var}',
            '    Common: lane defined twice, end missing, do/end mismatch',
            '- Architecture errors: arm64 vs x86_64 EXCLUDED_ARCHS — syntax is a space-separated string',
            '- Swift Package Manager: Package.swift dependencies array, product/target names must match exactly',
            '- CocoaPods Podfile: pod name/version syntax, target do/end blocks, source URL format',
            '- Carthage Cartfile: github/git/binary lines, version operators (~>, ==, >=)',
            '- HTML: unclosed tags (<div> with no </div>), mismatched close (</span> closing a <p>),',
            '    missing quotes around attribute values. Void elements (br/img/hr/input/meta/link/etc.)',
            '    never take a closing tag in either direction: do NOT add one if missing, and if one',
            '    already exists (e.g. stray </br>, reported as "closing tag has no matching opening tag"),',
            '    the fix is to DELETE that stray closing tag — do not wrap content between the tags or',
            '    restructure around it, the void element itself is fine, only the extra close tag is wrong.',
            '    <script>/<style> bodies follow JS/CSS rules, not HTML.',
            '- CSS/SCSS/LESS: every declaration needs property: value; — a missing colon or missing',
            '    trailing semicolon before the next declaration or the closing } is the most common break.',
            '    Selectors end in { not ; — do not add a semicolon after a selector. Nested rules (SCSS/LESS)',
            '    still need matched braces per level. & refers to the parent selector in SCSS/LESS, not bash.',
            '- SQL: the error reported here is STRUCTURAL ONLY (unbalanced parens, an unterminated string,',
            '    or an unterminated quoted identifier) — the validator deliberately does not check dialect-',
            '    specific syntax. Fix ONLY the structural problem reported (close the missing paren/quote).',
            '    Do NOT rewrite the query to a different dialect''s style, do NOT change LIMIT to/from TOP,',
            '    do NOT change backtick identifiers to double-quotes or vice versa, and do NOT add a',
            '    trailing semicolon if there wasn''t one — omitting it is valid in most engines for a single',
            '    statement and is not the reported error. SQL escapes a literal quote by DOUBLING it',
            "    ('O''Brien'), not with a backslash like other languages — do not introduce backslash escapes.",
            '    If the error mentions a dollar-quoted string ($$...$$ or $tag$...$tag$, common in PostgreSQL',
            '    function bodies), everything between the matching delimiters is LITERAL in real Postgres —',
            '    no character is ever escaped in there, not even a backslash or an unmatched single quote.',
            '    Fix ONLY by adding the missing closing delimiter with the SAME tag as the opener; do not',
            '    escape, requote, or otherwise alter the content inside the dollar-quoted block.',
            '- VUE (.vue Single File Component): the error is either a REAL vue-tsc type error (message',
            '    starts with "error TS" — fix it the same way you would a normal TypeScript error) OR a',
            '    structural finding prefixed "Vue <template>:", "Vue <script>:", or "Vue <style>:" — in that',
            '    case the prefix tells you WHICH block the problem is in; fix ONLY inside that block using',
            '    the same rules as standalone HTML/JS-or-TS/CSS respectively, and do NOT touch the other two',
            '    blocks or the <template>/<script>/<style> tags themselves. Preserve any lang="ts" or setup',
            '    attribute on the <script> tag exactly as written — do not add or remove it.',
            '',
            '11. ALSO include two top-level fields alongside "fixes" (both REQUIRED, even when',
            '    "fixes" is an empty array):',
            '    - "severity": one of "critical", "high", "medium", "low" — how disruptive THIS error is',
            '      to the build (critical = build cannot run at all / data-loss risk; high = build fails',
            '      every time until fixed; medium = build fails but the cause is narrow/contained; low =',
            '      cosmetic or style-only, would not normally block a build).',
            '    - "prevention_tip": ONE short sentence (max ~20 words) on how to avoid this specific class',
            '      of error in the future (e.g. a linter rule, a pre-commit hook, a naming convention). If',
            '      there is genuinely nothing useful to suggest, use an empty string "" — never invent a',
            '      generic platitude just to fill the field.',
            '',
            'RESPONSE FORMAT (raw JSON, fixes array):',
            '{ "severity": "high", "prevention_tip": "short one-sentence tip", "fixes": [ { "line_number": 28, "new_code": "corrected line content", "title": "short title", "confidence": 0.95 } ] }'
        ) -join "`n"

        $priorBlock = if (-not [string]::IsNullOrWhiteSpace($priorVersion)) {
            "=== PRIOR WORKING VERSION (reference for intended form) ===`n$priorVersion`n"
        } else { "" }

        $promptText = @(
            $rules, "",
            "=== PARSER ERROR (this triggered the review) ===",
            $parserError,
            "Parser reported near line: $errorLine — but scan the WHOLE file for ALL issues.",
            "",
            "=== FULL FILE: $filePath (review EVERY line) ===",
            $numberedContent,
            "",
            $priorBlock
        ) -join "`n"

        # ── Build request body — format differs per provider/API family ──
        if ($aiProvider -eq "AzureOpenAI" -and $aoaiIsClaude) {
            # CONFIRMED VIA RESEARCH: Claude on Azure Foundry speaks the
            # Anthropic Messages API, not OpenAI's Chat Completions shape.
            # Two structural differences that matter and are easy to get
            # wrong: (1) the system prompt is a TOP-LEVEL "system" string
            # field, NOT a {role:"system", ...} entry inside messages --
            # Anthropic's own API explicitly rejects a "system" role inside
            # messages with a 400 ("Unexpected role 'system'. The Messages
            # API accepts a top-level `system` parameter"). (2) max_tokens
            # is REQUIRED on every request (confirmed: omitting it is itself
            # a 400, "missing required parameter 'max_tokens'") -- it is not
            # optional the way some OpenAI-family fields are.
            $bodyJson = @{
                model       = $aoaiDeployment
                system      = "You are a precise code-fixing assistant. Respond ONLY with raw JSON matching the requested format -- no markdown, no commentary, no code fences."
                messages    = @(
                    @{ role = "user"; content = $promptText }
                )
                max_tokens  = 8192
            } | ConvertTo-Json -Depth 100 -Compress
        } elseif ($aiProvider -eq "AzureOpenAI") {
            # CONFIRMED VIA RESEARCH: switched from the Responses API to the
            # older Chat Completions API. The Responses API is region- and
            # feature-flag-gated (Microsoft's own current docs: "confirm that
            # your resource region supports the Responses API" — a real,
            # documented constraint, not every region/resource has it), which
            # explains a persistent 404 on BOTH /v1/responses and the
            # documented /openai/responses fallback path. Chat Completions has
            # no such gating and is the long-standing, universally-available
            # surface. Body format confirmed via Microsoft's own current docs:
            # a flat messages array with system+user roles, not input/
            # max_output_tokens (that shape is Responses-API-specific).
            # Covers GPT, Grok, DeepSeek, and any other Foundry catalog model
            # confirmed v1-chat-completions-compatible (see the
            # AZURE MODEL-FAMILY AUTO-DETECTION comment above) -- this is
            # NOT Azure-OpenAI-only despite the variable's name; it's just
            # "whatever speaks the OpenAI-shaped request/response".
            # BUGFIX: GPT-5-family and o-series reasoning models reject the
            # older "max_tokens" name outright (confirmed 400: "Unsupported
            # parameter: 'max_tokens' is not supported with this model. Use
            # 'max_completion_tokens' instead") while some legacy models
            # require the OPPOSITE and reject max_completion_tokens -- so the
            # key name itself must be chosen per-model, not just the value.
            # Built as a separate hashtable assignment (not inline in the
            # @{...} literal) because the KEY NAME differs, not just the
            # value -- PowerShell hashtable literals can't conditionally pick
            # a key name inline the way a ternary can pick a value.
            $bodyHash = @{
                messages = @(
                    @{ role = "system"; content = "You are a precise code-fixing assistant. Respond ONLY with raw JSON matching the requested format -- no markdown, no commentary, no code fences." }
                    @{ role = "user"; content = $promptText }
                )
            }
            if ($aoaiUsesMaxCompletionTokens) { $bodyHash["max_completion_tokens"] = 8192 } else { $bodyHash["max_tokens"] = 8192 }
            $bodyJson = $bodyHash | ConvertTo-Json -Depth 100 -Compress
        } else {
            # Gemini generateContent API format
            $bodyJson = @{
                contents         = @(@{ role = "user"; parts = @(@{ text = $promptText }) })
                generationConfig = @{
                    responseMimeType = "application/json"
                    thinkingConfig   = @{ thinkingBudget = 0 }
                }
            } | ConvertTo-Json -Depth 100 -Compress
        }
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)


        # Token waste control: cache identical error signatures.
        # Uses the FULL $parserError text, not a truncated prefix -- truncating risked
        # two genuinely different errors (e.g. differing only in which identifier was
        # misspelled, sharing a long boilerplate prefix) colliding into the same key and
        # returning the wrong cached fix. No real reason to truncate: this cache holds
        # at most a few dozen entries per run, and full text keeps keys debuggable.
        $cacheKey = "$filePath|$errorLine|$parserError"
        if ($script:aiCache.ContainsKey($cacheKey)) {
            Write-Host "    ♻️ Reusing cached response (no API call)."
            return $script:aiCache[$cacheKey]
        }

        # Cross-run persisted memory: reuse previously-validated fix before spending an AI call
        try {
            $memSig = Get-ErrorSignature -lang $langLabel -message $parserError
            $memHit = Serve-FixMemory -sig $memSig
            if ($null -ne $memHit -and @($memHit).Count -gt 0) {
                Write-Host "    🧠 Reusing fix from persisted memory (sig $memSig) — no API call."
                if ($null -ne $script:memServed) { $script:memServed[$filePath] = $memSig }
                $script:memStats.hits++
                # Update lastUsed timestamp so TTL is refreshed on active signatures
                if ($script:fixMemory.ContainsKey($memSig)) {
                    $script:fixMemory[$memSig].lastUsed = [datetime]::UtcNow.ToString('yyyy-MM-dd')
                }
                $script:aiCache[$cacheKey] = $memHit
                return $memHit
            }
        } catch { Write-Host "    ⓘ Memory lookup skipped: $($_.Exception.Message)" }

        $script:aiCallCount++

        # ── Call the active AI provider ───────────────────────────────────
        $resp = $null; $ok = $false; $r = 0
        # Separate from $r (network-transient-retry count) on purpose: $r can be
        # >0 purely from a 429/5xx/timeout retry on the FIRST call, which has nothing
        # to do with whether the self-correction pass below has been attempted.
        # Reusing $r here would silently skip self-correction after any network
        # hiccup, letting obviously-bad fixes (no-op old_code==new_code) through.
        $selfCorrectionAttempted = $false

        # ── CROSS-PROVIDER FALLBACK STATE ───────────────────────────────────
        # NEW: previously, any Azure-side failure (wrong key, model not
        # deployed, wrong endpoint) caused this function to return @() and
        # give up on the file entirely -- even when a perfectly working
        # GEMINI_API_KEY sat right there in the same variable group. That's
        # real, recoverable AI-fix capability being thrown away due to a
        # config problem with ONE provider, not because the file is
        # unfixable. $azureFailedRecoverably is set true only for failures
        # that are clearly about Azure's ACCOUNT/CONFIG (auth, 404, network)
        # rather than about the CONTENT of the request -- a 400 from a wrong
        # token-parameter name, for example, is Azure-specific and tells us
        # nothing about whether Gemini would also reject it, so 400 is
        # deliberately excluded from triggering fallback (it already has its
        # own specific, actionable error message above).
        $azureFailedRecoverably = $false

        if ($aiProvider -eq "AzureOpenAI" -and $aoaiIsClaude) {

            # CONFIRMED VIA RESEARCH: Claude on Azure Foundry lives at
            # <endpoint>/anthropic/v1/messages -- NOT
            # /openai/deployments/{name}/chat/completions (that path 404s for
            # Claude deployments; multiple independent real-world bug reports
            # confirm this exact failure mode). The deployment name is NOT a
            # URL path segment here -- it goes in the request BODY as the
            # "model" field instead (already set in $bodyJson above).
            $aoaiBaseTrimmed = $aoaiEndpoint.TrimEnd('/') -replace '/anthropic$',''
            $aoaiClaudeUrl = "$aoaiBaseTrimmed/anthropic/v1/messages"

            Write-Host "    🤖 Azure OpenAI (Claude) / $aoaiDeployment call #$($script:aiCallCount)"
            # Auth header: sources disagree on Azure's exact requirement here
            # (genuinely contested across independent reports at the time of
            # writing) -- "api-key" matches Azure's own established OpenAI
            # convention and the clearest direct head-to-head comparison
            # found, so it's used as the primary attempt. anthropic-version
            # is NOT contested -- every source agrees on 2023-06-01 and that
            # omitting it is itself a hard error.
            $hdrs = @{ "api-key" = $aoaiKey; "anthropic-version" = "2023-06-01"; "Content-Type" = "application/json" }
            while (-not $ok -and $r -lt 3) {
                try {
                    $resp = Invoke-RestMethod -Uri $aoaiClaudeUrl -Headers $hdrs -Method Post -Body $bodyBytes -TimeoutSec 180 -ErrorAction Stop
                    $ok = $true
                } catch {
                    $msg = $_.Exception.Message
                    if     ($msg -match "429|50[234]|timeout|connection") { $r++; Start-Sleep -Seconds 10 }
                    elseif ($msg -match "400|BadRequest") {
                        Write-Host "    ⚠️ Azure Claude 400 — check AZURE_OPENAI_DEPLOYMENT ('$aoaiDeployment') matches a real deployment name exactly. Skipping (not falling back -- a 400 is about THIS request's shape, not an account/config problem Gemini would avoid)."
                        return @()
                    } elseif ($msg -match "401|403|Unauthorized|Forbidden") {
                        Write-Host "    ⚠️ Azure Claude auth failed with the 'api-key' header. This specific point is genuinely contested across sources -- some Azure Anthropic endpoints require 'Authorization: Bearer <token>' (Entra ID) instead. Verify AZURE_OPENAI_KEY, or switch to Entra ID auth if this persists."
                        $azureFailedRecoverably = $true
                        break
                    } elseif ($msg -match "404") {
                        Write-Host "    ⚠️ Azure Claude 404 — verify the endpoint base URL doesn't already include '/anthropic' (this code strips a trailing one) and that the resource is genuinely a Foundry resource with this Claude deployment present."
                        $azureFailedRecoverably = $true
                        break
                    } else {
                        Write-Host "    ⚠️ Azure Claude error: $msg."
                        $azureFailedRecoverably = $true
                        break
                    }
                }
            }
            if ($azureFailedRecoverably) {
                # fall through to Gemini fallback block below -- $ok is still
                # $false here, which is exactly what that block checks for.
            } elseif (-not $ok) {
                return @()
            } else {
                # Parse Anthropic Messages API response: content is an ARRAY of
                # blocks (usually one, type "text"), NOT a single choices[0]
                # object the way OpenAI-shaped responses are -- confirmed via
                # Anthropic's own documented response schema.
                $raw = $null
                if ($null -ne $resp.content -and @($resp.content).Count -gt 0) {
                    $textBlock = $resp.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1
                    if ($null -ne $textBlock) { $raw = $textBlock.text }
                }
                if ([string]::IsNullOrWhiteSpace($raw)) {
                    Write-Host "    ⚠️ Azure Claude returned empty response."; return @()
                }
            }

        } elseif ($aiProvider -eq "AzureOpenAI") {

            # Builds the real Chat Completions URL from the BASE endpoint
            # (exactly what Azure's own portal "Endpoint" field shows, e.g.
            # https://your-resource.openai.azure.com/ -- confirmed directly
            # against a real portal screenshot) + deployment name + a
            # verified-current api-version, rather than expecting
            # AZURE_OPENAI_ENDPOINT to already contain a hand-constructed
            # path. api-version 2024-10-21 confirmed current/stable via
            # Microsoft's own SDK changelog (multiple independent sources).
            # Covers GPT, Grok, DeepSeek, and any other catalog model
            # confirmed v1-chat-completions-compatible -- see the
            # AZURE MODEL-FAMILY AUTO-DETECTION comment above.
            $aoaiBaseTrimmed = $aoaiEndpoint.TrimEnd('/')
            $aoaiChatUrl = "$aoaiBaseTrimmed/openai/deployments/$aoaiDeployment/chat/completions?api-version=2024-10-21"

            Write-Host "    🤖 Azure OpenAI / $aoaiDeployment call #$($script:aiCallCount)"
            $hdrs = @{ "api-key" = $aoaiKey; "Content-Type" = "application/json" }
            while (-not $ok -and $r -lt 3) {
                try {
                    $resp = Invoke-RestMethod -Uri $aoaiChatUrl -Headers $hdrs -Method Post -Body $bodyBytes -TimeoutSec 180 -ErrorAction Stop
                    $ok = $true
                } catch {
                    $msg = $_.Exception.Message
                    if     ($msg -match "429|50[234]|timeout|connection") { $r++; Start-Sleep -Seconds 10 }
                    elseif ($msg -match "400|BadRequest") {
                        Write-Host "    ⚠️ Azure OpenAI 400 for deployment '$aoaiDeployment'. Common cause: this model requires 'max_completion_tokens' instead of 'max_tokens' (or vice versa) -- confirm the model name matches the gpt-5/o-series detection pattern if this is unexpected. Raw error: $msg. Skipping (not falling back -- a 400 is about THIS request's shape, not an account/config problem Gemini would avoid)."
                        return @()
                    } elseif ($msg -match "401|403|Unauthorized|Forbidden") {
                        Write-Host "    ⚠️ Azure OpenAI auth failed — verify AZURE_OPENAI_KEY."
                        $azureFailedRecoverably = $true
                        break
                    } else {
                        Write-Host "    ⚠️ Azure OpenAI error: $msg."
                        $azureFailedRecoverably = $true
                        break
                    }
                }
            }
            if ($azureFailedRecoverably) {
                # fall through to Gemini fallback block below.
            } elseif (-not $ok) {
                return @()
            } else {
                # Parse Chat Completions response: choices[0].message.content
                $raw = $null
                if ($null -ne $resp.choices -and @($resp.choices).Count -gt 0) {
                    $raw = $resp.choices[0].message.content
                }
                if ([string]::IsNullOrWhiteSpace($raw)) {
                    Write-Host "    ⚠️ Azure OpenAI returned empty response."; return @()
                }
            }

        } else {

            Write-Host "    🤖 Gemini / gemini-2.5-flash call #$($script:aiCallCount)"
            $hdrs = @{ "x-goog-api-key" = $geminiKey; "Content-Type" = "application/json" }
            while (-not $ok -and $r -lt 3) {
                try {
                    $resp = Invoke-RestMethod -Uri $geminiUri -Headers $hdrs -Method Post -Body $bodyBytes -TimeoutSec 180 -ErrorAction Stop
                    $ok = $true
                } catch {
                    $msg = $_.Exception.Message
                    if     ($msg -match "429|50[234]|timeout|connection") { $r++; Start-Sleep -Seconds 10 }
                    elseif ($msg -match "400|BadRequest") {
                        Write-Host "    ⚠️ Gemini 400 — verify API key supports gemini-2.5-flash. Skipping."
                        return @()
                    } else {
                        Write-Host "    ⚠️ Gemini error: $msg. Skipping."
                        return @()
                    }
                }
            }
            if (-not $ok) { return @() }

            # Parse Gemini candidates response
            $cand = $null
            if ($null -ne $resp.candidates -and @($resp.candidates).Count -gt 0) { $cand = $resp.candidates[0] }
            if ($null -eq $cand) { Write-Host "    ⚠️ Gemini returned no candidates."; return @() }
            if ($cand.finishReason -eq 'MAX_TOKENS')    { Write-Host "    ⚠️ Gemini MAX_TOKENS — response truncated, discarding."; return @() }
            if ($cand.finishReason -in @('SAFETY','BLOCKLIST','PROHIBITED_CONTENT')) { Write-Host "    ⚠️ Gemini blocked content."; return @() }
            if ($null -eq $cand.content -or $null -eq $cand.content.parts -or @($cand.content.parts).Count -eq 0) {
                Write-Host "    ⚠️ Gemini returned empty content."; return @()
            }
            $raw = $cand.content.parts[0].text
            if ([string]::IsNullOrWhiteSpace($raw)) { Write-Host "    ⚠️ Gemini empty text."; return @() }
        }

        # ── CROSS-PROVIDER FALLBACK: Azure failed recoverably, try Gemini ───
        # Only runs when Azure was the PRIMARY provider, it just failed with
        # an account/config-level error (not a content-level 400), AND a
        # Gemini key is actually present to fall back to. Builds and sends
        # the SAME prompt via Gemini's request shape, reusing $promptText
        # (already built above, identical content regardless of provider).
        if ($azureFailedRecoverably) {
            if ([string]::IsNullOrWhiteSpace($geminiKey)) {
                Write-Host "    ⚠️ No GEMINI_API_KEY configured to fall back to. Skipping this file."
                return @()
            }
            Write-Host "    🔁 Falling back to Gemini after Azure failure (same file, same prompt)..."
            $fallbackBody = @{
                contents         = @(@{ role = "user"; parts = @(@{ text = $promptText }) })
                generationConfig = @{
                    responseMimeType = "application/json"
                    thinkingConfig   = @{ thinkingBudget = 0 }
                }
            } | ConvertTo-Json -Depth 100 -Compress
            $fallbackBytes = [System.Text.Encoding]::UTF8.GetBytes($fallbackBody)
            $fbOk = $false; $fbR = 0; $fbResp = $null
            Write-Host "    🤖 Gemini (fallback) / gemini-2.5-flash call #$($script:aiCallCount)"
            $fbHdrs = @{ "x-goog-api-key" = $geminiKey; "Content-Type" = "application/json" }
            while (-not $fbOk -and $fbR -lt 3) {
                try {
                    $fbResp = Invoke-RestMethod -Uri $geminiUri -Headers $fbHdrs -Method Post -Body $fallbackBytes -TimeoutSec 180 -ErrorAction Stop
                    $fbOk = $true
                } catch {
                    $fbMsg = $_.Exception.Message
                    if ($fbMsg -match "429|50[234]|timeout|connection") { $fbR++; Start-Sleep -Seconds 10 }
                    else { Write-Host "    ⚠️ Gemini fallback also failed: $fbMsg. Skipping."; return @() }
                }
            }
            if (-not $fbOk) { Write-Host "    ⚠️ Gemini fallback exhausted retries. Skipping."; return @() }

            $fbCand = $null
            if ($null -ne $fbResp.candidates -and @($fbResp.candidates).Count -gt 0) { $fbCand = $fbResp.candidates[0] }
            if ($null -eq $fbCand) { Write-Host "    ⚠️ Gemini fallback returned no candidates."; return @() }
            if ($fbCand.finishReason -eq 'MAX_TOKENS') { Write-Host "    ⚠️ Gemini fallback MAX_TOKENS — truncated, discarding."; return @() }
            if ($fbCand.finishReason -in @('SAFETY','BLOCKLIST','PROHIBITED_CONTENT')) { Write-Host "    ⚠️ Gemini fallback blocked content."; return @() }
            if ($null -eq $fbCand.content -or $null -eq $fbCand.content.parts -or @($fbCand.content.parts).Count -eq 0) {
                Write-Host "    ⚠️ Gemini fallback returned empty content."; return @()
            }
            $raw = $fbCand.content.parts[0].text
            if ([string]::IsNullOrWhiteSpace($raw)) { Write-Host "    ⚠️ Gemini fallback empty text."; return @() }
            # NOTE: $selfCorrectionAttempted's later retry-on-bad-fix logic
            # below still branches on $aiProvider to pick AzureOpenAI/Gemini
            # body shape -- since the ORIGINAL $aiProvider was "AzureOpenAI",
            # a self-correction retry after a successful Gemini fallback
            # would incorrectly try Azure again. Force it to Gemini's shape
            # for the remainder of this call now that we know Azure is down.
            $aiProvider = "Gemini"
        }

        # ── Parse JSON response — identical for both providers ─────────────
        $clean = $raw -replace '(?s)^```json\s*', '' -replace '(?s)\s*```$', '' -replace ',\s*([\}\]])', '$1'
        try {
            $parsed = $clean | ConvertFrom-Json -Depth 100 -ErrorAction Stop
            $fixes  = if ($null -ne $parsed.fixes) { @($parsed.fixes) } else { @() }

            # ── Retry with refined prompt if fixes look wrong ──────────────
            # If the AI returned fixes but they have obvious issues (old_code == new_code,
            # or new_code contains structural errors detectable quickly), retry ONCE
            # with the validation error included so the AI can self-correct.
            if ($fixes.Count -gt 0 -and -not $selfCorrectionAttempted) {
                $selfCorrectionAttempted = $true
                $badFixes = $fixes | Where-Object {
                    [string]::IsNullOrWhiteSpace($_.new_code) -or
                    ($_.old_code -eq $_.new_code) -or
                    ($_.new_code -match 'INSERT_MANUAL_VALUE_HERE')
                }
                if (@($badFixes).Count -eq $fixes.Count -and @($badFixes).Count -gt 0) {
                    Write-Host "    🔄 All $(@($badFixes).Count) fix(es) appear invalid — retrying with refined prompt..."
                    $refinedPrompt = $promptText + "`n`n[IMPORTANT: Your previous response contained fixes where old_code equals new_code or new_code was empty. These are no-ops. Please provide a meaningful, different replacement for new_code that actually fixes the error: $parserError]"
                    $retryBodyJson = if ($aiProvider -eq "AzureOpenAI" -and $aoaiIsClaude) {
                        @{ model=$aoaiDeployment; system="You are a precise code-fixing assistant. Respond ONLY with raw JSON matching the requested format -- no markdown, no commentary, no code fences."; messages=@(@{role="user";content=$refinedPrompt}); max_tokens=8192 } | ConvertTo-Json -Depth 100 -Compress
                    } elseif ($aiProvider -eq "AzureOpenAI") {
                        # Same key-name bugfix as the main call above: GPT-5/
                        # o-series reject max_tokens with a 400; other models
                        # (confirmed: GPT-4 turbo-2024-04-09) reject the
                        # opposite name -- must be chosen per deployed model.
                        $retryHash = @{ messages = @(@{role="system";content="You are a precise code-fixing assistant. Respond ONLY with raw JSON matching the requested format -- no markdown, no commentary, no code fences."},@{role="user";content=$refinedPrompt}) }
                        if ($aoaiUsesMaxCompletionTokens) { $retryHash["max_completion_tokens"] = 8192 } else { $retryHash["max_tokens"] = 8192 }
                        $retryHash | ConvertTo-Json -Depth 100 -Compress
                    } else {
                        @{ contents=@(@{role="user";parts=@(@{text=$refinedPrompt})}); generationConfig=@{responseMimeType="application/json";thinkingConfig=@{thinkingBudget=0}} } | ConvertTo-Json -Depth 100 -Compress
                    }
                    $retryBytes = [System.Text.Encoding]::UTF8.GetBytes($retryBodyJson)
                    $retryOk = $false; $retryResp = $null
                    try {
                        if ($aiProvider -eq "AzureOpenAI" -and $aoaiIsClaude) {
                            $retryResp = Invoke-RestMethod -Uri $aoaiClaudeUrl -Headers @{"api-key"=$aoaiKey;"anthropic-version"="2023-06-01";"Content-Type"="application/json"} -Method Post -Body $retryBytes -TimeoutSec 180 -EA Stop
                            $retryTextBlock = if ($retryResp.content) { $retryResp.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1 } else { $null }
                            $retryRaw = if ($null -ne $retryTextBlock) { $retryTextBlock.text } else { $null }
                        } elseif ($aiProvider -eq "AzureOpenAI") {
                            $retryResp = Invoke-RestMethod -Uri $aoaiChatUrl -Headers @{"api-key"=$aoaiKey;"Content-Type"="application/json"} -Method Post -Body $retryBytes -TimeoutSec 180 -EA Stop
                            $retryRaw = if ($retryResp.choices -and @($retryResp.choices).Count -gt 0) { $retryResp.choices[0].message.content } else { $null }
                        } else {
                            $retryResp = Invoke-RestMethod -Uri $geminiUri -Headers @{"x-goog-api-key"=$geminiKey;"Content-Type"="application/json"} -Method Post -Body $retryBytes -TimeoutSec 180 -EA Stop
                            $rc = if ($retryResp.candidates) { $retryResp.candidates[0] } else { $null }
                            $retryRaw = if ($rc -and $rc.content -and $rc.content.parts) { $rc.content.parts[0].text } else { $null }
                        }
                        if (-not [string]::IsNullOrWhiteSpace($retryRaw)) {
                            $retryClean = $retryRaw -replace '(?s)^```json\s*',''-replace '(?s)\s*```$','' -replace ',\s*([\}\]])', '$1'
                            $retryParsed = $retryClean | ConvertFrom-Json -Depth 100 -EA Stop
                            $retryFixes = if ($retryParsed.fixes) { @($retryParsed.fixes) } else { @() }
                            if ($retryFixes.Count -gt 0) { $fixes = $retryFixes; Write-Host "    ✅ Retry produced $($fixes.Count) improved fix(es)." }
                        }
                    } catch { Write-Host "    ⚠️ Refined prompt retry failed: $($_.Exception.Message)" }
                }
            }

            $script:aiCache[$cacheKey] = $fixes
            $script:memStats.misses++
            if ($fixes.Count -gt 0 -and $null -ne $script:memLearn) {
                try {
                    $script:memLearn[$filePath] = @{
                        Sig   = (Get-ErrorSignature -lang $langLabel -message $parserError)
                        Fixes = $fixes
                    }
                    $script:memStats.newEntries++
                } catch {}
            }
            # Carry severity/prevention_tip through to the main loop -- see
            # the SEVERITY / PREVENTION-TIP CARRY-THROUGH comment above for
            # why this is script-scope state rather than a return-value
            # change. Only stashed when present and non-empty; absent or
            # malformed values are silently skipped rather than guessed at --
            # an unknown severity is better left unset than defaulted wrong.
            try {
                if ($null -ne $script:fileSeverity -and $parsed.severity -and
                    "$($parsed.severity)".ToLower() -in @('critical','high','medium','low')) {
                    $script:fileSeverity[$filePath] = "$($parsed.severity)".ToLower()
                }
                if ($null -ne $script:filePreventionTip -and -not [string]::IsNullOrWhiteSpace("$($parsed.prevention_tip)")) {
                    $script:filePreventionTip[$filePath] = "$($parsed.prevention_tip)".Trim()
                }
            } catch {}
            return $fixes
        } catch { Write-Host "    ⚠️ AI JSON parse failed: $($_.Exception.Message)"; return @() }
    }

    # ──────────────────────────────────────────────────────────────────
    #  IDENTIFY CANDIDATE FILES  (from error logs + changed files)
    # ──────────────────────────────────────────────────────────────────
    Write-Host "[INFO] Collecting logs to identify failing files..."
    $logs = Invoke-ADORestMethod -Uri "$collectionUri$teamProject/_apis/build/builds/$buildId/logs?api-version=7.1"
    $logText = [System.Text.StringBuilder]::new()
    if ($null -ne $logs -and $null -ne $logs.value) {
        foreach ($log in $logs.value) {
            if ($null -ne $log.url) {
                $t = Invoke-ADORestMethod -Uri $log.url
                if (-not [string]::IsNullOrWhiteSpace($t)) { $logText.AppendLine($t) | Out-Null }
            }
        }
    }
    $logStr = $logText.ToString()

    # ── LOG SIZE CAP: trim oversized logs to reduce triage runtime ────────
    # Xcode iOS build logs can be 50-100MB (thousands of Swift compilation
    # lines). Most of these are successful compilation steps with zero value
    # for error detection. Real errors live at the beginning (early failures)
    # or at the tail (fastlane summary, final error message).
    # Cap: keep first 150KB (startup/early errors) + last 100KB (fastlane tail).
    $maxHead = 150000; $maxTail = 100000
    if ($logStr.Length -gt ($maxHead + $maxTail)) {
        $head = $logStr.Substring(0, $maxHead)
        $tail = $logStr.Substring($logStr.Length - $maxTail)
        $logStr = $head + "`n[... $(($logStr.Length - $maxHead - $maxTail) / 1KB -as [int])KB of mid-build compilation output trimmed for performance ...]`n" + $tail
        Write-Host "[INFO] Build log trimmed: showing first 150KB + last 100KB of $([int]($logText.Length/1KB))KB total"
    }

    # HashSet with OrdinalIgnoreCase prevents the same file from being added
    # twice even when it comes from different sources with different path casing
    # or slash direction — which happens on macOS agents (case-insensitive FS).
    # With a HashSet, Add() is idempotent: duplicates are silently dropped.
    $candidatePaths = [System.Collections.Generic.HashSet[string]]([System.StringComparer]::OrdinalIgnoreCase)

    # ── TIER 0: Build-tool error extraction (most precise) ────────────────
    # Parse the log using each build tool's specific error format.
    # This gives us the EXACT file + line the compiler / linter reported.
    # Much more precise than the generic log regex scan below.
    $buildErrors = Extract-BuildErrors -logText $logStr
    $buildErrorMap = @{}  # path → line number, used later to seed the AI with context
    foreach ($be in $buildErrors) {
        [void]$candidatePaths.Add($be.File)
        # Store the first reported error line per file for context
        if (-not $buildErrorMap.ContainsKey($be.File)) { $buildErrorMap[$be.File] = $be.Line }
        Write-Host "[Tier0] $($be.Tool) error → $($be.File):$($be.Line)"
    }

    # ── IMPORT ERROR MAP ─────────────────────────────────────────────────
    # Separately detect import/reference errors that pass syntax validation
    # (python3 -m py_compile, node --check, etc. don't catch missing imports).
    # These files are already in candidatePaths from Tier 0 above, but
    # Get-SyntaxError would mark them CLEAN — so we need this map to force
    # the AI call even when the parser returns Ok=$true.
    $importErrorMap = Get-ImportErrorMap -logText $logStr
    foreach ($kv in $importErrorMap.GetEnumerator()) {
        [void]$candidatePaths.Add($kv.Key)   # ensure it's a candidate even if missed by Tier 0
        Write-Host "[ImportMap] Added candidate: $($kv.Key) — $($kv.Value.Message)"
    }

    # ── CREDENTIAL / SECRET / APP-ID ERROR DETECTOR ──────────────────────
    # When a build fails due to missing/wrong credentials, app IDs, certificates,
    # or secrets, the triage cannot auto-fix them. Instead it generates TODO items
    # with INSERT_MANUAL_VALUE_HERE that appear in the Teams card as actionable
    # checklist items. The remediator skips these automatically — developers use them
    # as a checklist of what to configure before re-running the build.
    #
    # Coverage: Firebase, Apple signing, Fastlane Match, App Store Connect,
    #           Google Play, Azure KeyVault, Secure Files, App Center, Dynatrace,
    #           Slack, and generic missing ENV variables.
    function Get-CredentialErrors {
        param([string]$logText)
        $todos = [System.Collections.Generic.List[object]]::new()

        # ── CRITICAL: narrow search to ERROR-CONTEXT lines only ─────────────
        # The full Xcode build log is 50-100MB and mentions every framework name
        # (Firebase, Dynatrace, AppCenter, etc.) in successful compilation steps.
        # Scanning the full log causes ALL credential patterns to fire as false
        # positives. We extract only lines that contain actual error indicators,
        # PLUS the last 150 lines (fastlane summary + final error always at tail).
        $allLines  = $logText -split "`r?`n"
        $errorLines = $allLines | Where-Object {
            $_ -match '(?i)(\berror\b|\[!]|\bfail(ed|ure)?\b|\bhalted\b|\bfatal\b|\babort\b|unauthorized|forbidden|\b40[134]\b|nil\b|\bnot set\b|\bnot found\b|missing.*(?:key|token|id|file)|invalid.*(?:request|credential|key|token|id|app)|exception|no value has been set)'
        }
        $tailLines = if ($allLines.Count -gt 150) { $allLines[-150..-1] } else { $allLines }
        # Combine: unique error lines + tail (where fastlane summary lives)
        $searchLines = @($errorLines) + @($tailLines) | Select-Object -Unique
        $searchText  = $searchLines -join "`n"

        if ([string]::IsNullOrWhiteSpace($searchText)) { return $todos }
        Write-Host "[CredFix] Scanning $($searchLines.Count) error-context lines (out of $($allLines.Count) total)"

        $credChecks = @(

            # ── Firebase App Distribution (App ID / service credentials) ───────
            [PSCustomObject]@{
                Pattern    = '(?i)(firebase_app_distribution.*(?:halted|failed|error)|App Distribution halted|Invalid request.*status_code.*404|firebase.*app_id.*(?:nil|not set|missing|empty|invalid)|FIREBASE_APP_ID.*not set|No value.*firebase_app_id|firebase_app_id.*required|firebase.*404)'
                Title      = 'Firebase App ID invalid or not set — firebase_app_distribution returned 404 (app not found in Firebase project)'
                Var        = 'FIREBASE_APP_ID'
                Where      = 'Firebase Console → Project Settings → Your Apps → copy App ID (format: 1:NNNNN:ios:XXXX). Set as ADO pipeline variable or pass as lane option firebase_app_id'
                FileSearch = 'firebase_app_distribution|firebase_app_id'
            },
            [PSCustomObject]@{
                Pattern    = '(?i)(SECUREFILEPATH.*not found|service_credentials_file.*not found|Unable to download secure file.*google|GoogleService-Info.*not found|google-services.*not found|firebase.*service.*credential.*not|FIREBASE_TOKEN.*not set)'
                Title      = 'Firebase service credentials file not found — SECUREFILEPATH or google-services.json missing'
                Var        = 'SECUREFILEPATH'
                Where      = 'ADO Pipeline → Library → Secure Files → upload google-services.json or service-account.json → reference as $(SECUREFILEPATH) in YAML'
                FileSearch = 'service_credentials_file|SECUREFILEPATH|google.services'
            },

            # ── Apple Code Signing ──────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(No signing certificate|CodeSign.*FAILED|code sign error|provisioning profile.*not found|no profiles for.*bundle identifier|signing identity.*not found|codesign.*failed|APPLE_CERTIFICATE.*not set|P12.*password.*incorrect|certificate.*expired|Your account.*valid.*certificate)'
                Title      = 'Apple code signing failed — certificate or provisioning profile missing, expired, or wrong password'
                Var        = 'APPLE_CERTIFICATE_P12 / APPLE_CERTIFICATE_PASSWORD / PROVISIONING_PROFILE'
                Where      = 'ADO Library → Variable Group: APPLE_CERTIFICATE_PASSWORD, APPLE_CERTIFICATE_P12 (base64-encoded). Or run: fastlane match --readonly to verify'
                FileSearch = 'code_sign_identity|provisioning_profile_specifier|APPLE_CERT|codesign'
            },

            # ── Fastlane Match ──────────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(MATCH_PASSWORD.*not set|match.*decrypt.*failed|MATCH_GIT_BASIC_AUTHORIZATION.*not set|match.*authentication.*failed|fastlane match.*failed|MATCH_KEYCHAIN_PASSWORD.*not set)'
                Title      = 'Fastlane Match credentials missing — MATCH_PASSWORD or git auth not set'
                Var        = 'MATCH_PASSWORD / MATCH_GIT_BASIC_AUTHORIZATION'
                Where      = 'ADO Pipeline secrets: MATCH_PASSWORD = encryption password used when match was initialized, MATCH_GIT_BASIC_AUTHORIZATION = base64(user:PAT) for certificates repo'
                FileSearch = 'MATCH_PASSWORD|fastlane match|sync_code_signing'
            },

            # ── App Store Connect / TestFlight ──────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(APP_STORE_CONNECT_API_KEY.*not set|FASTLANE_PASSWORD.*not set|FASTLANE_SESSION.*expired|iTunesConnect.*auth|ITC_PROVIDER.*not set|App Store Connect.*401|testflight.*auth.*fail|APPLE_ID.*not set.*deliver|deliver.*apple.id.*missing)'
                Title      = 'App Store Connect credentials missing — API key or Apple ID authentication failed'
                Var        = 'APP_STORE_CONNECT_API_KEY_ID / APP_STORE_CONNECT_API_KEY_ISSUER_ID / APP_STORE_CONNECT_API_KEY_CONTENT'
                Where      = 'App Store Connect → Users and Access → Integrations → App Store Connect API → New Key → download .p8 → add all 3 variables to ADO Pipeline secrets'
                FileSearch = 'upload_to_testflight|upload_to_app_store|APP_STORE_CONNECT|deliver'
            },

            # ── Azure KeyVault ──────────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(keyvault.*access.*denied|azure.*vault.*unauthorized|vault.*403.*forbidden|key vault.*permission|KeyVault.*secret.*not.*found|Unable to get secret)'
                Title      = 'Azure KeyVault access denied — pipeline service principal lacks Get/List permission'
                Var        = 'AZURE_KEYVAULT_SECRET (KeyVault name)'
                Where      = 'Azure Portal → Key Vault → Access Policies (or RBAC) → add pipeline Service Principal with "Key Vault Secrets User" role'
                FileSearch = 'AzureKeyVault|key.vault|keyvault'
            },

            # ── ADO Secure Files ────────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(Unable to download secure file|secure.file.*not found|DownloadSecureFile.*failed|secure file.*does not exist)'
                Title      = 'ADO Secure File not found — file referenced in pipeline does not exist in Library'
                Var        = 'Secure File name (check DownloadSecureFile@1 task in YAML)'
                Where      = 'ADO → Pipelines → Library → Secure Files → upload the required file. Ensure pipeline has access (grant permission in Secure Files settings)'
                FileSearch = 'DownloadSecureFile|SECUREFILEPATH|secureFile'
            },

            # ── Google Play Store ───────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(SUPPLY_JSON_KEY.*not set|google.play.*json.*key.*not|google_play_json_key.*missing|play.*store.*auth.*fail|supply.*401|GOOGLE_PLAY_JSON_KEY)'
                Title      = 'Google Play Store JSON key missing — SUPPLY_JSON_KEY not configured'
                Var        = 'GOOGLE_PLAY_JSON_KEY_DATA'
                Where      = 'Google Play Console → Setup → API access → Service account → Create key (JSON) → download → add content as ADO secret variable GOOGLE_PLAY_JSON_KEY_DATA'
                FileSearch = 'upload_to_play_store|supply|SUPPLY_JSON_KEY'
            },

            # ── App Center ──────────────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(APPCENTER_API_TOKEN.*not set|appcenter.*token.*missing|appcenter.*401|appcenter.*unauthorized)'
                Title      = 'App Center API token not set — APPCENTER_API_TOKEN missing'
                Var        = 'APPCENTER_API_TOKEN'
                Where      = 'App Center → Account Settings → API Tokens → New API token → copy → add to ADO Pipeline secret variable APPCENTER_API_TOKEN'
                FileSearch = 'appcenter_upload|APPCENTER_API_TOKEN|appcenter'
            },

            # ── Dynatrace ───────────────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(DYNATRACE.*token.*not|dynatrace.*api.*key.*miss|dynatrace.*unauthorized|DT_API_TOKEN.*not set)'
                Title      = 'Dynatrace API token not set — DT_API_TOKEN missing'
                Var        = 'DT_API_TOKEN / DYNATRACE_API_TOKEN'
                Where      = 'Dynatrace → Access Tokens → Generate token with mobileSymbolication, DataExport scopes → ADO Pipeline secret variable'
                FileSearch = 'DT_API_TOKEN|DYNATRACE_API_TOKEN|dynatrace_upload'
            },

            # ── Slack ───────────────────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(SLACK_URL.*not set|slack.*webhook.*invalid|slack.*hook.*fail|slack.*401|slack.*channel.*not.*found)'
                Title      = 'Slack webhook URL not set — SLACK_URL missing or invalid'
                Var        = 'SLACK_URL'
                Where      = 'api.slack.com → Your Apps → Incoming Webhooks → Add New Webhook → copy URL → ADO Pipeline variable SLACK_URL'
                FileSearch = 'SLACK_URL|slack.*webhook|slack.*channel'
            },

            # ── iOS Code Signing — provisioning profile / certificate ────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(No matching provisioning profiles found|provisioning profile.*doesn.*t match|Code Signing Error.*development team|DEVELOPMENT_TEAM.*not set|No profiles for.*were found|requires a development team|signing.*identity.*not found|certificate.*has expired|profile.*expired|codesign.*failed|CODE_SIGN_IDENTITY.*not found|The selected behavior is to always fail|Provisioning profile.*is not valid|code signing is required for product type)'
                Title      = 'iOS code signing failed — provisioning profile or certificate missing/expired'
                Var        = 'MATCH_PASSWORD / MATCH_GIT_BASIC_AUTHORIZATION / DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY'
                Where      = 'Use fastlane match: fastlane match development. For manual setup: Xcode → Signing & Capabilities → set DEVELOPMENT_TEAM. Add MATCH_PASSWORD and MATCH_GIT_BASIC_AUTHORIZATION to ADO Pipeline secrets. Renew expired certificates at developer.apple.com → Certificates.'
                FileSearch = 'DEVELOPMENT_TEAM|CODE_SIGN_IDENTITY|provisioning|codesign|match|sync_code_signing'
            },

            # ── Android Keystore / Signing ───────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(keystore.*not found|jarsigner.*key.store.*not found|signing.*keystore.*fail|KEYSTORE_PATH.*not set|ANDROID_KEYSTORE.*not set|KEY_ALIAS.*not set|KEYSTORE_PASSWORD.*not set|cannot.sign.*keystore|Unable to read key from keystore|Keystore file.*not found|Error opening keystore|Execution failed for task.*signRelease)'
                Title      = 'Android signing keystore not found or credentials missing'
                Var        = 'KEYSTORE_PATH / KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD'
                Where      = 'Generate: keytool -genkey -v -keystore release.jks -alias mykey -keyalg RSA -keysize 2048 -validity 10000. Upload release.jks to ADO Library → Secure Files. Set KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD as ADO Pipeline secrets. In Gradle: storeFile = file(System.getenv("KEYSTORE_PATH"))'
                FileSearch = 'KEYSTORE_PATH|ANDROID_KEYSTORE|storeFile|keyAlias|storePassword|signingConfig'
            },

            # ── AWS Credentials ──────────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(AWS_ACCESS_KEY_ID.*not set|AWS_SECRET_ACCESS_KEY.*not set|NoCredentialProviders|Unable to locate credentials|aws.*credential.*not.*configured|InvalidClientTokenId|AuthFailure.*AWS|aws.*unauthorized|The AWS Access Key Id.*does not exist|ExpiredTokenException)'
                Title      = 'AWS credentials not configured — AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY missing'
                Var        = 'AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION'
                Where      = 'AWS Console → IAM → Users → Security credentials → Create access key. Add to ADO Pipeline secrets: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY. Set AWS_DEFAULT_REGION (e.g. us-east-1). For cross-account: use IAM role with aws sts assume-role.'
                FileSearch = 'AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|aws_s3|upload_to_s3|AWSCredentials'
            },

            # ── Docker Registry Auth ─────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(docker.*unauthorized.*registry|docker.*access.*denied|unauthorized.*to access repository|denied.*requested access|docker login.*failed|Error response from daemon.*pull access denied|Pulling from.*denied|no credentials found|docker push.*unauthorized)'
                Title      = 'Docker registry authentication failed — registry credentials not configured'
                Var        = 'DOCKER_USERNAME / DOCKER_PASSWORD / DOCKER_REGISTRY_URL'
                Where      = 'ADO → Pipelines → Service connections → Docker Registry → add credentials. Or add pipeline step: docker login $DOCKER_REGISTRY_URL -u $(DOCKER_USERNAME) -p $(DOCKER_PASSWORD). For Azure Container Registry: use AzureCLI@2 with az acr login.'
                FileSearch = 'docker login|DOCKER_REGISTRY|DOCKER_USERNAME|DOCKER_PASSWORD|containerRegistry'
            },

            # ── Git SSH / HTTPS Authentication ───────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(Permission denied \(publickey\)|Host key verification failed|fatal.*Could not read from remote|git.*Authentication failed|ssh.*key.*not found|unable to access.*403.*Forbidden|remote.*permission.*denied|Repository not found|error.*Permissions 0644 for.*are too open|invalid.*credentials.*git)'
                Title      = 'Git authentication failed — SSH key or HTTPS credentials not configured'
                Var        = 'MATCH_GIT_BASIC_AUTHORIZATION / GIT_SSH_KEY / System.AccessToken'
                Where      = 'HTTPS: set MATCH_GIT_BASIC_AUTHORIZATION = base64("username:PAT"). SSH: add key to ADO → Project Settings → SSH Public Keys. ADO repos: add AllowScriptsToAccessOAuthToken: true to pipeline YAML and use $(System.AccessToken).'
                FileSearch = 'MATCH_GIT_BASIC_AUTHORIZATION|GIT_SSH_KEY|git remote|git clone|git_url'
            },

            # ── npm Registry Authentication ──────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(npm ERR.*401 Unauthorized|ENEEDAUTH.*need auth|npm.*login.*required|_authToken.*not.*set|npm.*403.*Forbidden.*private|Unauthorized to access package|npm audit.*403|npm publish.*403)'
                Title      = 'npm registry authentication failed — .npmrc auth token not configured'
                Var        = 'NPM_AUTH_TOKEN / NODE_AUTH_TOKEN'
                Where      = 'Private npm: get token from npm registry (npm login → cat ~/.npmrc). Add to ADO Pipeline secrets as NPM_AUTH_TOKEN. Add pipeline step: echo "//registry.npmjs.org/:_authToken=$(NPM_AUTH_TOKEN)" > .npmrc. Azure Artifacts: use NpmAuthenticate@0 task with $(System.AccessToken).'
                FileSearch = 'npmrc|NPM_AUTH_TOKEN|NODE_AUTH_TOKEN|npm publish|npm install.*private'
            },

            # ── Android SDK / Build Tools / License ──────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(License for package.*not accepted|ANDROID_HOME.*not set|ANDROID_SDK_ROOT.*not set|Failed to install the following Android SDK|SDK.*build.tools.*not installed|NDK.*not installed|android.sdk.path.*not.*set|SDK location not found)'
                Title      = 'Android SDK not found or build-tools license not accepted'
                Var        = 'ANDROID_HOME / ANDROID_SDK_ROOT'
                Where      = 'Accept licenses: yes | sdkmanager --licenses. Install build tools: sdkmanager "build-tools;X.X.X". Set ANDROID_HOME to SDK path. For ADO hosted agents use the AndroidSdkManager@0 task or install Gradle task which auto-detects SDK.'
                FileSearch = 'ANDROID_HOME|ANDROID_SDK_ROOT|compileSdkVersion|buildToolsVersion|sdkmanager'
            },

            # ── Gradle wrapper version incompatibility ────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(Minimum supported Gradle version is|Gradle version.*not supported|Please use Gradle.*or higher|gradle-wrapper.*version.*incompatible|The project uses Gradle.*which is incompatible|Could not find compatible Gradle version|Unsupported Gradle version)'
                Title      = 'Gradle wrapper version incompatible with Android Gradle Plugin version'
                Var        = 'GRADLE_VERSION (in gradle/wrapper/gradle-wrapper.properties)'
                Where      = 'Update gradle/wrapper/gradle-wrapper.properties: change distributionUrl to match the required Gradle version. See https://developer.android.com/studio/releases/gradle-plugin for the compatibility table. Example: distributionUrl=https://services.gradle.org/distributions/gradle-X.X-bin.zip'
                FileSearch = 'gradle-wrapper.properties|distributionUrl|gradle_version'
            },

            # ── Google Play Store JSON key / upload key ───────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(PLAY_STORE_JSON_KEY.*not set|google_play.*json.*key.*missing|supply.*unauthorized|upload_to_play_store.*credential.*fail|Google Play API.*authentication.*failed|googlePlayApiKey.*not.*found|ServiceAccountCredential.*json.*not|play_store_json_key.*nil)'
                Title      = 'Google Play Store upload credentials not configured — PLAY_STORE_JSON_KEY missing'
                Var        = 'PLAY_STORE_JSON_KEY (path to service account JSON)'
                Where      = 'Google Play Console → Setup → API access → Create service account → download JSON key → upload to ADO Library → Secure Files as play_store_key.json. Set PLAY_STORE_JSON_KEY = $(play_store_key.json.secureFilePath) in pipeline. Fastlane: set json_key_file in your supply/upload_to_play_store lane.'
                FileSearch = 'PLAY_STORE_JSON_KEY|json_key_file|google_play|supply|upload_to_play_store'
            },

            # ── Sentry DSN / Auth token ──────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(SENTRY_DSN.*not set|sentry.*auth.*token.*missing|sentry.*api.*key.*nil|SENTRY_AUTH_TOKEN.*not)'
                Title      = 'Sentry DSN or auth token not configured'
                Var        = 'SENTRY_DSN / SENTRY_AUTH_TOKEN'
                Where      = 'Sentry → Settings → API → Auth Tokens → create token → ADO Pipeline secrets: SENTRY_DSN (from Project Settings > Client Keys) and SENTRY_AUTH_TOKEN'
                FileSearch = 'SENTRY_DSN|SENTRY_AUTH_TOKEN|sentry_upload'
            },

            # ── TestFairy ───────────────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(TESTFAIRY_API_KEY.*not set|testfairy.*api.*key.*nil|testfairy.*unauthorized)'
                Title      = 'TestFairy API key not configured'
                Var        = 'TESTFAIRY_API_KEY'
                Where      = 'TestFairy → Account Settings → API Key → copy → ADO Pipeline secret TESTFAIRY_API_KEY'
                FileSearch = 'TESTFAIRY_API_KEY|testfairy'
            },

            # ── Bitrise ─────────────────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(BITRISE_API_TOKEN.*not set|bitrise.*api.*token.*nil|bitrise.*unauthorized)'
                Title      = 'Bitrise API token not configured'
                Var        = 'BITRISE_API_TOKEN'
                Where      = 'Bitrise → Account Settings → Security → Personal Access Tokens → generate → ADO Pipeline secret BITRISE_API_TOKEN'
                FileSearch = 'BITRISE_API_TOKEN|bitrise'
            },

            # ── Fastlane Spaceship / Apple auth (generic) ───────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(spaceship.*authentication.*failed|Apple ID.*two-factor.*not supported|SPACESHIP_ONLY_ALLOW_HTTPS.*expired|apple.*session.*expired|itc.*password.*incorrect)'
                Title      = 'Fastlane Spaceship / Apple ID authentication failed — session expired or 2FA issue'
                Var        = 'APPLE_ID / FASTLANE_PASSWORD / FASTLANE_SESSION / APP_STORE_CONNECT_API_KEY'
                Where      = 'Use App Store Connect API key instead of Apple ID/password (recommended for CI). Generate at App Store Connect → Users and Access → Integrations → Keys. Set APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_API_KEY_ISSUER_ID, APP_STORE_CONNECT_API_KEY_CONTENT'
                FileSearch = 'APPLE_ID|FASTLANE_PASSWORD|FASTLANE_SESSION|spaceship|app_store_connect'
            },

            # ── Xcode version too old / developer tools not installed ───────────
            [PSCustomObject]@{
                Pattern    = '(?i)(requires Xcode [\d.]+ or (later|newer)|Xcode [\d.]+ is required|xcode-select.*no developer tools|xcrun: error.*no such file|Your iOS.*requires a minimum of Xcode|Command Line Tools.*not installed)'
                Title      = 'Xcode version too old or Command Line Tools not installed on agent'
                Var        = 'XCODE_VERSION / DEVELOPER_DIR'
                Where      = 'Use fastlane xcversion plugin: add xcversion(version: "~> X.X") to your lane. Or install tools: sudo xcode-select --install. For hosted agents: use a newer macOS agent pool image that includes the required Xcode version.'
                FileSearch = 'xcversion|xcode_install|DEVELOPER_DIR|xcode-select'
            },

            # ── Python private PyPI registry auth ────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(pip.*401 unauthorized|pip.*403 forbidden|Could not find.*version.*private|PYPI_API_TOKEN.*not set|PIP_INDEX_URL.*auth.*failed|twine.*401|Could not authenticate.*pip|no matching distribution found.*private)'
                Title      = 'Python pip authentication failed — private PyPI registry credentials not configured'
                Var        = 'PYPI_API_TOKEN / PIP_INDEX_URL / PIP_EXTRA_INDEX_URL'
                Where      = 'PyPI: set PYPI_API_TOKEN, use pip install --index-url https://pypi.org/simple/ --extra-index-url https://token:$PYPI_API_TOKEN@private.pypi.org/. Azure Artifacts: set PIP_INDEX_URL to your feed URL and authenticate with $(System.AccessToken).'
                FileSearch = 'PYPI_API_TOKEN|PIP_INDEX_URL|PIP_EXTRA_INDEX_URL|twine upload|pip install'
            },

            # ── Azure Container Registry ─────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(\.azurecr\.io.*unauthorized|acr.*login.*failed|AZURE_CONTAINER_REGISTRY.*not set|az acr login.*failed|docker.*\.azurecr\.io.*unauthorized|unauthorized.*azurecr)'
                Title      = 'Azure Container Registry login failed — ACR credentials not configured'
                Var        = 'AZURE_CONTAINER_REGISTRY / ACR_USERNAME / ACR_PASSWORD'
                Where      = 'Azure Portal → Container Registry → Access keys → enable Admin user → copy username + password. Add ACR_USERNAME and ACR_PASSWORD as ADO Pipeline secrets. OR use az acr login --name myregistry with service principal via AzureCLI@2 task.'
                FileSearch = 'azurecr.io|AZURE_CONTAINER_REGISTRY|acr login|ACR_USERNAME|ACR_PASSWORD'
            },

            # ── JFrog Artifactory ────────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(artifactory.*401 unauthorized|jfrog.*auth.*failed|ARTIFACTORY_URL.*not set|ARTIFACTORY_USER.*not set|ARTIFACTORY_PASSWORD.*not set|Could not resolve.*artifactory|jfrog rt.*credentials.*missing|Unable to resolve.*jfrog)'
                Title      = 'JFrog Artifactory credentials not configured'
                Var        = 'ARTIFACTORY_URL / ARTIFACTORY_USER / ARTIFACTORY_API_KEY'
                Where      = 'JFrog Platform → User Management → API Key → Generate API key. Add ARTIFACTORY_URL, ARTIFACTORY_USER, ARTIFACTORY_API_KEY as ADO Pipeline secrets. Configure in build tool: Gradle (gradle.properties), Maven (settings.xml), npm (.npmrc with registry + _authToken).'
                FileSearch = 'ARTIFACTORY_URL|ARTIFACTORY_USER|ARTIFACTORY_API_KEY|jfrog|artifactory'
            },

            # ── GitHub Container Registry (ghcr.io) ──────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(ghcr\.io.*unauthorized|ghcr\.io.*denied|GITHUB_TOKEN.*not set|ghcr.*login.*failed|docker.*ghcr\.io.*auth.*fail)'
                Title      = 'GitHub Container Registry (ghcr.io) authentication failed'
                Var        = 'GITHUB_TOKEN / CR_PAT'
                Where      = 'GitHub → Settings → Developer settings → Personal access tokens → New PAT with write:packages and read:packages scopes. Add as CR_PAT in ADO Pipeline secrets. Login step: echo $(CR_PAT) | docker login ghcr.io -u USERNAME --password-stdin'
                FileSearch = 'ghcr.io|GITHUB_TOKEN|CR_PAT'
            },

            # ── Fastlane Match — certificate repo specific errors ────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(match.*decrypt.*failed|match.*invalid.*passphrase|match.*can.*t.*clone|MATCH_PASSWORD.*wrong|match.*openssl.*error|match.*error.*decrypting|fastlane match.*failed to decrypt)'
                Title      = 'Fastlane Match decryption failed — MATCH_PASSWORD is wrong or cert repo inaccessible'
                Var        = 'MATCH_PASSWORD / MATCH_GIT_BASIC_AUTHORIZATION'
                Where      = 'Verify MATCH_PASSWORD is the exact passphrase used when match was initialized (case-sensitive). Test: MATCH_PASSWORD=yourpass fastlane match development --readonly. Re-run fastlane match nuke if certs are corrupted. Ensure MATCH_GIT_BASIC_AUTHORIZATION = base64("username:PAT") is valid.'
                FileSearch = 'MATCH_PASSWORD|MATCH_GIT_BASIC_AUTHORIZATION|sync_code_signing|match'
            },

            # ── CocoaPods trunk / spec repo auth ────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(cocoapods.*trunk.*forbidden|pod.*trunk.*push.*not.*authorized|cocoapods.*token.*missing|COCOAPODS_TRUNK_TOKEN.*not)'
                Title      = 'CocoaPods trunk push not authorized — COCOAPODS_TRUNK_TOKEN missing'
                Var        = 'COCOAPODS_TRUNK_TOKEN'
                Where      = 'Run: pod trunk register your@email.com "Your Name" — then check email to confirm. Get token from ~/.netrc or set COCOAPODS_TRUNK_TOKEN in ADO Pipeline secrets'
                FileSearch = 'COCOAPODS_TRUNK_TOKEN|pod trunk'
            },

            # ── App Store Connect API key (JWT — new method) ─────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(ASC_KEY_ID.*not.*set|ASC_ISSUER_ID.*not.*set|ASC_KEY_CONTENT.*not.*set|asc.*api.*key.*missing|app_store_connect.*api.*key.*not.*set|Could not find App Store Connect API key|jwt.*authentication.*failed.*app.*store|AuthKey.*\.p8.*not.*found)'
                Title      = 'App Store Connect API key (JWT) not configured — ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_CONTENT missing'
                Var        = 'ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_CONTENT (base64 of .p8 file)'
                Where      = 'App Store Connect → Users and Access → Integrations → App Store Connect API → Generate API Key (.p8 file). Set ASC_KEY_ID (key ID), ASC_ISSUER_ID (issuer UUID), ASC_KEY_CONTENT (base64-encoded .p8 file contents) as ADO Pipeline secrets. In Fastfile: app_store_connect_api_key(key_id: ENV["ASC_KEY_ID"], issuer_id: ENV["ASC_ISSUER_ID"], key_content: ENV["ASC_KEY_CONTENT"])'
                FileSearch = 'ASC_KEY_ID|ASC_ISSUER_ID|ASC_KEY_CONTENT|app_store_connect_api_key'
            },

            # ── Huawei AppGallery Connect credentials ─────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(HUAWEI_CLIENT_ID.*not.*set|HUAWEI_CLIENT_SECRET.*not.*set|huawei.*appgallery.*credential|AppGallery.*authentication.*failed|huawei.*connect.*api.*error|agcCredentialFilePath.*not.*found)'
                Title      = 'Huawei AppGallery Connect credentials not configured — HUAWEI_CLIENT_ID / HUAWEI_CLIENT_SECRET missing'
                Var        = 'HUAWEI_CLIENT_ID, HUAWEI_CLIENT_SECRET'
                Where      = 'AppGallery Connect → Users and permissions → API key → Create → download agconnect-services.json. Set HUAWEI_CLIENT_ID and HUAWEI_CLIENT_SECRET as ADO Pipeline secrets. In Fastfile: huawei_appgallery_connect(client_id: ENV["HUAWEI_CLIENT_ID"], client_secret: ENV["HUAWEI_CLIENT_SECRET"], app_id: "...", apk_path: "...")'
                FileSearch = 'HUAWEI_CLIENT_ID|HUAWEI_CLIENT_SECRET|huawei_appgallery'
            },

            # ── Android Gradle signing credentials ───────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(SIGNING_KEY_ALIAS.*not.*set|SIGNING_STORE_PASSWORD.*not.*set|SIGNING_KEY_PASSWORD.*not.*set|storePassword.*not.*found|keyPassword.*empty|signingConfig.*null|Keystore.*was.*tampered|keytool.*error.*keystore)'
                Title      = 'Android Gradle signing credentials missing — SIGNING_KEY_ALIAS / SIGNING_STORE_PASSWORD / SIGNING_KEY_PASSWORD not set'
                Var        = 'SIGNING_KEY_ALIAS, SIGNING_STORE_PASSWORD, SIGNING_KEY_PASSWORD, SIGNING_STORE_FILE'
                Where      = 'In build.gradle signingConfigs block set: storeFile file(System.getenv("SIGNING_STORE_FILE")), storePassword System.getenv("SIGNING_STORE_PASSWORD"), keyAlias System.getenv("SIGNING_KEY_ALIAS"), keyPassword System.getenv("SIGNING_KEY_PASSWORD"). Upload the .jks file to ADO Library → Secure Files as android-keystore.jks. Set all four variables as ADO Pipeline secrets and SIGNING_STORE_FILE to $(android-keystore.jks.secureFilePath)'
                FileSearch = 'SIGNING_KEY_ALIAS|SIGNING_STORE_PASSWORD|signingConfig|storePassword|keyAlias'
            },

            # ── Swift Package Manager private repo auth ───────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(could not resolve package.*authentication|SPM.*authentication.*failed|swift package.*401|swift package.*403|netrc.*not.*found|package.*credential.*denied|xcode.*private.*package.*auth)'
                Title      = 'Swift Package Manager private repository authentication failed — netrc or GitHub token not configured'
                Var        = 'SPM_GITHUB_TOKEN (or ~/.netrc entry)'
                Where      = 'For GitHub-hosted SPM packages: create ~/.netrc with: machine github.com login x-access-token password $GITHUB_TOKEN. In ADO pipeline: add a script step before build to write netrc: echo "machine github.com login x-access-token password $(GITHUB_TOKEN)" > ~/.netrc && chmod 600 ~/.netrc. Alternatively configure XcodeCloud / Xcode SPM credential in Keychain Access'
                FileSearch = 'Package.swift|spm|swift package|.netrc'
            },

            # ── Sonatype Nexus / Maven private repo ───────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(NEXUS_USERNAME.*not.*set|NEXUS_PASSWORD.*not.*set|Could not resolve.*nexus|maven.*repository.*authentication.*failed|401.*nexus|403.*maven|Could not GET.*repository.*Unauthorized)'
                Title      = 'Sonatype Nexus / Maven repository authentication failed — NEXUS_USERNAME / NEXUS_PASSWORD missing'
                Var        = 'NEXUS_USERNAME, NEXUS_PASSWORD'
                Where      = 'In build.gradle: maven { url "https://nexus.company.com/repository/maven-releases/"; credentials { username System.getenv("NEXUS_USERNAME"); password System.getenv("NEXUS_PASSWORD") } }. Set NEXUS_USERNAME and NEXUS_PASSWORD as ADO Pipeline secrets. For gradle.properties approach: use -PnexusUsername=$(NEXUS_USERNAME) -PnexusPassword=$(NEXUS_PASSWORD) in the Gradle task arguments'
                FileSearch = 'NEXUS_USERNAME|NEXUS_PASSWORD|nexus|maven.*credentials'
            },

            # ── BrowserStack credentials ──────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(BROWSERSTACK_USERNAME.*not.*set|BROWSERSTACK_ACCESS_KEY.*not.*set|browserstack.*authentication.*fail|browserstack.*api.*key.*invalid|browserstack.*unauthorized|bs.*local.*auth.*fail)'
                Title      = 'BrowserStack credentials not configured — BROWSERSTACK_USERNAME / BROWSERSTACK_ACCESS_KEY missing'
                Var        = 'BROWSERSTACK_USERNAME, BROWSERSTACK_ACCESS_KEY'
                Where      = 'BrowserStack Account → Summary → Automate / App Automate → Access Key. Set BROWSERSTACK_USERNAME and BROWSERSTACK_ACCESS_KEY as ADO Pipeline secrets. For Fastlane: set ENV["BROWSERSTACK_USERNAME"] and ENV["BROWSERSTACK_ACCESS_KEY"] or pass as plugin parameters'
                FileSearch = 'BROWSERSTACK_USERNAME|BROWSERSTACK_ACCESS_KEY|browserstack'
            },

            # ── Codecov token ─────────────────────────────────────────────────────
            [PSCustomObject]@{
                Pattern    = '(?i)(CODECOV_TOKEN.*not.*set|codecov.*unauthorized|upload.*coverage.*failed.*token|codecov.*authentication.*error|codecov.*403)'
                Title      = 'Codecov token not configured — CODECOV_TOKEN missing'
                Var        = 'CODECOV_TOKEN'
                Where      = 'Codecov → Repository Settings → General → Token. Set CODECOV_TOKEN as an ADO Pipeline secret. In pipeline: use the Codecov Bash uploader: bash <(curl -s https://codecov.io/bash) -t $(CODECOV_TOKEN) -f coverage.xml or use the codecov uploader binary'
                FileSearch = 'CODECOV_TOKEN|codecov'
            },

            # ── Generic nil ENV variable (catch-all) ────────────────────────────
            [PSCustomObject]@{
                Pattern    = "(?i)(No value has been set for|ENV\['[A-Z_]+'\].*nil|ENV\[`"[A-Z_]+`"\].*nil|required.*variable.*not set|is required.*not.*provided)"
                Title      = 'A required environment variable is nil or not set — check Fastfile for ENV[] references'
                Var        = 'Check Fastfile/lane definition for ENV[] keys that are nil at runtime'
                Where      = 'Search Fastfile for ENV[] references. Add missing values as ADO Pipeline variables (non-secret) or secrets (sensitive). Run fastlane env to list all required variables'
                FileSearch = 'ENV\['
            }
        )

        # ── Location detection: find exact file + line in repo ─────────────────
        # The triage runs as part of the failing build so source files ARE on disk.
        # For each detected credential error we search the repo for the specific
        # action/variable reference, giving the developer an exact code location.
        function Find-CredLocation {
            param([string]$SearchPattern, [string]$RepoRoot)
            if ([string]::IsNullOrEmpty($SearchPattern) -or [string]::IsNullOrEmpty($RepoRoot)) { return $null }

            # These files contain the same credential keywords as PATTERN TEXT in their own code.
            # Searching them would annotate CI/CD infrastructure instead of user Fastfiles.
            $aiInfra    = '(?i)(ai-triage|ai-interactive|triage-webhook|ai-remediator)'
            # Android build output folders added alongside iOS/general noise so candidate
            # file discovery skips generated Java/Kotlin and Gradle intermediate files.
            $buildNoise = '[\\/](\.git|node_modules|Pods|DerivedData|vendor|\.build|Carthage|xcarchive|\.gradle|\.cxx|__pycache__)[\\/]|[\\/]build[\\/](intermediates|generated|outputs|tmp|kotlin|classes|reports)[\\/]'

            try {
                # Priority 1 — Fastfile: canonical location for ALL Fastlane credential calls
                $hit = Get-ChildItem -Path $RepoRoot -Recurse -Filter 'Fastfile' -Depth 8 -EA SilentlyContinue |
                       Where-Object { $_.FullName -notmatch $buildNoise } |
                       Select-String -Pattern $SearchPattern -EA SilentlyContinue |
                       Select-Object -First 1
                if ($null -ne $hit) { return $hit }

                # Priority 2 — Pipeline YAML files, excluding AI infrastructure files
                $hit = Get-ChildItem -Path $RepoRoot -Recurse -Depth 8 -EA SilentlyContinue |
                       Where-Object {
                           $_.FullName -notmatch $buildNoise -and
                           $_.FullName -notmatch $aiInfra -and
                           $_.Extension -in @('.yaml', '.yml')
                       } |
                       Select-String -Pattern $SearchPattern -EA SilentlyContinue |
                       Select-Object -First 1
                if ($null -ne $hit) { return $hit }

                # Priority 3 — Shell/Ruby scripts (not AI infra)
                $hit = Get-ChildItem -Path $RepoRoot -Recurse -Depth 8 -EA SilentlyContinue |
                       Where-Object {
                           $_.FullName -notmatch $buildNoise -and
                           $_.FullName -notmatch $aiInfra -and
                           $_.Extension -in @('.rb', '.sh', '.ps1')
                       } |
                       Select-String -Pattern $SearchPattern -EA SilentlyContinue |
                       Select-Object -First 1
                return $hit
            } catch { return $null }
        }

        $repoRoot = $env:BUILD_SOURCESDIRECTORY

        $seen = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($cc in $credChecks) {
            if ($searchText -match $cc.Pattern) {
                # De-duplicate: only one TODO per variable name
                if (-not $seen.Add($cc.Var)) { continue }

                # Find exact file + line in repo where this credential is referenced
                $locFile = 'ADO-pipeline-configuration'
                $locLine = 0
                $locCode = ''
                if ($cc.FileSearch -and $repoRoot) {
                    $hit = Find-CredLocation -SearchPattern $cc.FileSearch -RepoRoot $repoRoot
                    if ($null -ne $hit) {
                        $locFile = $hit.Path.Replace($repoRoot,'').TrimStart([IO.Path]::DirectorySeparatorChar).TrimStart('/').Replace('\','/')
                        $locLine = $hit.LineNumber
                        $locCode = $hit.Line.Trim()
                        Write-Host "[CredFix] Located at: $locFile line $locLine → $locCode"
                    }
                }

                $todos.Add([PSCustomObject]@{
                    file_path    = $locFile
                    line_number  = $locLine
                    title        = "⚠️ MANUAL ACTION REQUIRED: $($cc.Title)"
                    old_code     = $locCode
                    new_code     = "INSERT_MANUAL_VALUE_HERE | Variable: $($cc.Var) | Where to set: $($cc.Where)"
                    confidence   = 1.0
                    _fullContent = $null
                })
                Write-Host "[CredFix] ⚠️ Credential issue detected: $($cc.Title)"
            }
        }
        return $todos
    }
    # These never appear as a file path in the log so importErrorMap misses
    # them entirely. Detect and fix Gemfile directly from the build log.
    # allFixes must exist before we add bundler fixes — initialize it here
    # if it hasn't been created yet (it is also initialized at line ~1576
    # but that's AFTER this call).
    if ($null -eq $allFixes) { $allFixes = [System.Collections.Generic.List[object]]::new() }

    # ── CREDENTIAL / SECRET / APP-ID ERRORS ──────────────────────────────
    # Generates TODO items for Firebase, signing, Match, App Store Connect,
    # KeyVault, Secure Files, Google Play, App Center, Dynatrace, Slack etc.
    # Uses INSERT_MANUAL_VALUE_HERE → remediator skips → Teams card shows checklist.
    $credErrors = Get-CredentialErrors -logText $logStr
    foreach ($ce in $credErrors) {
        $allFixes.Add($ce)
        Write-Host "[CredFix] TODO added to Teams card: $($ce.title)"
    }

    $bundlerFixes = Get-BundlerFixes -logText $logStr
    foreach ($bf in $bundlerFixes) {
        [void]$candidatePaths.Add($bf.file_path)
        $allFixes.Add($bf)
        Write-Host "[BundlerFix] Fix queued: $($bf.title)"
    }

    # ── Fastlane plugin fixes — DIFFERENT error class from bundler ────────
    # 'Could not find action, lane or variable X' is a RUNTIME Fastlane error,
    # not a bundler error. Get-BundlerFixes cannot catch it. This dedicated
    # function maps action names → plugin gems without any AI call.
    $pluginFixes = Get-FastlanePluginFixes -logText $logStr
    foreach ($pf in $pluginFixes) {
        [void]$candidatePaths.Add($pf.file_path)
        $allFixes.Add($pf)
        Write-Host "[PluginFix] Fix queued: $($pf.title)"
    }

    # ── CocoaPods missing pod — "Unable to find a specification for 'X'" ─────
    $podFixes = Get-CocoaPodsFixes -logText $logStr
    foreach ($cpf in $podFixes) {
        [void]$candidatePaths.Add($cpf.file_path)
        $allFixes.Add($cpf)
        Write-Host "[PodFix] Fix queued: $($cpf.title)"
    }

    # ── npm/Node.js missing module — "Cannot find module 'X'" ───────────────
    $npmFixes = Get-NpmModuleFixes -logText $logStr
    foreach ($nf in $npmFixes) {
        [void]$candidatePaths.Add($nf.file_path)
        $allFixes.Add($nf)
        Write-Host "[NpmFix] Fix queued: $($nf.title)"
    }

    # ── Python missing module — "ModuleNotFoundError: No module named 'X'" ──
    $pyFixes = Get-PythonModuleFixes -logText $logStr
    foreach ($pyf in $pyFixes) {
        [void]$candidatePaths.Add($pyf.file_path)
        $allFixes.Add($pyf)
        Write-Host "[PythonFix] Fix queued: $($pyf.title)"
    }

    # ── Ruby/Bundler version mismatch — "Your Ruby version is X, but Gemfile specified Y" ──
    $rubyFixes = Get-RubyVersionFixes -logText $logStr
    foreach ($rbf in $rubyFixes) {
        [void]$candidatePaths.Add($rbf.file_path)
        $allFixes.Add($rbf)
        Write-Host "[RubyVersionFix] Fix queued: $($rbf.title)"
    }

    # ════════════════════════════════════════════════════════════════════════════
    # PHASE 0 — COMPREHENSIVE BUILD PREFLIGHT AUDIT (ALWAYS runs first)
    # Covers all 5 failure categories regardless of what appears in the log.
    # A build that dies in 1 second gets exactly the same depth of analysis
    # as a build that runs for 45 minutes and fails at the last step.
    # ════════════════════════════════════════════════════════════════════════════
    $preflightFixes = Invoke-BuildPreflightAudit -logText $logStr
    foreach ($pf in $preflightFixes) {
        [void]$candidatePaths.Add($pf.file_path)
        $allFixes.Add($pf)
        Write-Host "[Phase0] Fix queued: $($pf.title)"
    }

    # ── Makefile tab indentation — GNU make "missing separator" ─────────────
    $mkFixes = Get-MakefileFixes -logText $logStr
    foreach ($mkf in $mkFixes) {
        [void]$candidatePaths.Add($mkf.file_path)
        $allFixes.Add($mkf)
        Write-Host "[MakefileFix] Fix queued: $($mkf.title)"
    }

    # ── Android: Gradle dependency resolution — "Could not resolve X:Y:Z" ──
    $gradleFixes = Get-GradleDependencyFixes -logText $logStr
    foreach ($gf in $gradleFixes) {
        [void]$candidatePaths.Add($gf.file_path)
        $allFixes.Add($gf)
        Write-Host "[GradleFix] Fix queued: $($gf.title)"
    }

    # ── iOS/macOS: Swift Package Manager dependency failure ───────────────
    $spmFixes = Get-SwiftPackageFixes -logText $logStr
    foreach ($sf in $spmFixes) {
        [void]$candidatePaths.Add($sf.file_path)
        $allFixes.Add($sf)
        Write-Host "[SPMFix] Fix queued: $($sf.title)"
    }

    # ── iOS/macOS: Carthage build failure / Xcode 12+ xcframeworks ────────
    $carthageFixes = Get-CarthageFixes -logText $logStr
    foreach ($cf in $carthageFixes) {
        [void]$candidatePaths.Add($cf.file_path)
        $allFixes.Add($cf)
        Write-Host "[CarthageFix] Fix queued: $($cf.title)"
    }

    # ── iOS/macOS: Xcode scheme / workspace not found ─────────────────────
    $schemeFixes = Get-XcodeSchemeFixes -logText $logStr
    foreach ($xf in $schemeFixes) {
        [void]$candidatePaths.Add($xf.file_path)
        $allFixes.Add($xf)
        Write-Host "[XcodeSchemeFix] Fix queued: $($xf.title)"
    }

    Write-Host "[INFO] Tier 0 (build-tool error parse): $($candidatePaths.Count) precise candidate(s)."

    # Require at least one path separator so bare filenames like "tmp.sh"
    # (our own checker temp files that appear in error message output)
    # and external URLs cannot be matched.
    # html/htm/css/scss/less/sass/sql/vue included so ANY tool's error output
    # that merely mentions a stylesheet/markup/query/Vue-component file path
    # (stylelint, htmlhint, postcss, webpack, a bundler, a SQL migration
    # runner, vue-tsc, or anything else) surfaces it as a candidate — this
    # engine doesn't special-case one tool's format, it just needs the path
    # text to appear somewhere in the log.
    $fileRegex = '(?i)((?:[a-zA-Z0-9_\-\.]+[/\\])+[a-zA-Z0-9_\-\.]+\.(?:yml|yaml|sh|ps1|rb|py|js|ts|java|css|cs|vb|fs|go|kt|kts|swift|php|json|xml|gradle|pro|csproj|tf|tfvars|groovy|toml|rs|html?|scss|less|sass|sql|vue)|(?:[a-zA-Z0-9_\-\.]+[/\\])+(?:Dockerfile|Jenkinsfile|Fastfile|Gemfile|Podfile))'

    # Paths matching these patterns are NEVER valid project candidates.
    # Extended to filter Xcode build artifacts that flood the external files list:
    # IntermediateBuildFilesPath, BuildProductsPath, framework internals, .dSYM,
    # ANSI color code remnants (35m/0m prefix), prebuilt Swift modules, app bundles.
    $logExcludePattern = '(?i)(_temp/|/runner/work/|usr/local/lib|/gems/|rubygems|bundler-\d|node_modules|\.browserstack\.|api-cloud\.|ai_fixes|\.azuredevops|IntermediateBuildFilesPath|BuildProductsPath|UninstalledProducts|SwiftExplicitPrecompiledModules|prebuilt-modules|Applications/Xcode|\.dSYM/|\.framework/Modules|\.xcarchive/|xcworkspace/|DerivedData/|build/intermediates/|build/generated/|build/outputs/|build/kotlin/|\.gradle/caches/|\.gradle/wrapper/|\.cxx/|GeneratedFiles/|R\.java|BuildConfig\.java)'

    foreach ($m in [regex]::Matches($logStr, $fileRegex)) {
        $p = $m.Groups[1].Value.TrimStart('/\')
        if ($p -match $logExcludePattern) { continue }
        # Skip path-prefixed Gemfile/Podfile/Fastfile entries that appear in bundler
        # or fastlane log output (e.g. "fastlane/Gemfile", "ios/Gemfile"). These are
        # NOT repo files — they come from tool output like "Using fastlane/Gemfile".
        # Get-BundlerFixes handles the actual Gemfile fix via recursive disk search.
        if ($p -match '(?i)(Gemfile|Podfile)$' -and $p -match '[/\\]') { continue }
        # Skip ANSI color code remnant paths: "35mFirebaseAnalytics.framework/..."
        # These are terminal color codes (\e[35m) whose \e[ was stripped, leaving "35m"
        # prepended to the real path. They are NEVER valid repo files.
        if ($p -match '^\d{1,2}m[A-Z]') { continue }
        # Skip app bundle content paths that start with ".app/"
        if ($p -match '^\.app/') { continue }
        if ($p -notmatch '(?i)\.(png|jpg|jpeg|gif|pdf|dll|exe|zip|ipa|apk)$') { [void]$candidatePaths.Add($p) }
    }
    foreach ($named in @('Fastfile','Podfile','Gemfile','build.gradle','settings.gradle','AndroidManifest.xml','proguard-rules.pro','gradle.properties')) {
        if ($logStr -match "\b$([regex]::Escape($named))\b") { [void]$candidatePaths.Add($named) }
    }

    # Always include files changed in this build's commits (the likely culprits)
    $priorCommitId = $null
    $buildChanges = Invoke-ADORestMethod -Uri "$collectionUri$teamProject/_apis/build/builds/$buildId/changes?api-version=7.1&`$top=20"
    if ($null -ne $buildChanges -and $null -ne $buildChanges.value) {
        foreach ($bc in $buildChanges.value) {
            $changes = Invoke-ADORestMethod -Uri "$collectionUri$teamProject/_apis/git/repositories/$repoId/commits/$($bc.id)/changes?api-version=7.1"
            if ($null -ne $changes -and $null -ne $changes.changes) {
                foreach ($ch in $changes.changes) {
                    if ($ch.changeType -notmatch 'delete' -and $ch.item.path -match '(?i)\.(sh|ps1|rb|py|js|jsx|ts|tsx|yml|yaml|java|css|cs|vb|fs|go|kt|kts|swift|php|json|xml|gradle|pro|csproj|tf|tfvars|groovy|toml|rs|html?|scss|less|sass|sql|vue)$|Fastfile|Gemfile|Podfile|Dockerfile|Jenkinsfile|build\.gradle|settings\.gradle') {
                        [void]$candidatePaths.Add($ch.item.path.TrimStart('/'))
                    }
                }
            }
        }
    }
    Write-Host "[INFO] Tier 1 (logs + build changes): $($candidatePaths.Count) candidate(s)."

    # ── PLATFORM DETECTION (informational only — triage is fully cross-platform) ─
    # Infers iOS/Android/Other from candidate file extensions so the log is clear
    # about which platform's knowledge base will be active.
    $hasSwift   = $candidatePaths | Where-Object { $_ -match '\.swift$' }
    $hasGradle  = $candidatePaths | Where-Object { $_ -match '\.gradle$|build\.gradle|settings\.gradle' }
    $hasKotlin  = $candidatePaths | Where-Object { $_ -match '\.kt$|\.kts$' }
    $hasJava    = $candidatePaths | Where-Object { $_ -match '\.java$' }
    $detectedPlatform = if ($hasSwift) { '🍎 iOS / macOS (Swift detected)' } `
                        elseif ($hasGradle -or $hasKotlin -or $hasJava) { '🤖 Android / JVM (Gradle/Kotlin/Java detected)' } `
                        else { '⚙️ General / Cross-platform' }
    Write-Host "[INFO] Platform: $detectedPlatform"

    # ── TIER 2: Last 5 commits on this branch ─────────────────────────────
    # Why 5: if a file was broken in commit 5 and fixed in commit 3, the CURRENT
    # version of that file is clean. Get-SyntaxError will return Ok=true and the
    # file will be skipped with no error reported — correct behaviour.
    # We fetch each file at HEAD ($sourceVersion), NOT at the historical commit,
    # so we only see CURRENT errors, never already-fixed historical ones.
    $histUrl = "$collectionUri$teamProject/_apis/git/repositories/$repoId/commits" +
               "?searchCriteria.itemVersion.version=$([uri]::EscapeDataString($cleanFailedBranch))" +
               "&searchCriteria.itemVersion.versionType=branch&searchCriteria.`$top=5&api-version=7.1"
    $histList = Invoke-ADORestMethod -Uri $histUrl
    if ($null -ne $histList -and $null -ne $histList.value) {
        foreach ($hc in $histList.value) {
            $hChanges = Invoke-ADORestMethod -Uri "$collectionUri$teamProject/_apis/git/repositories/$repoId/commits/$($hc.commitId)/changes?api-version=7.1"
            if ($null -ne $hChanges -and $null -ne $hChanges.changes) {
                foreach ($ch in $hChanges.changes) {
                    if ($ch.changeType -notmatch 'delete' -and $ch.item.path -match '(?i)\.(sh|ps1|rb|py|js|jsx|ts|tsx|yml|yaml|java|css|cs|vb|fs|go|kt|kts|swift|php|json|xml|gradle|pro|csproj|tf|tfvars|groovy|toml|rs|html?|scss|less|sass|sql|vue)$|Fastfile|Gemfile|Podfile|Dockerfile|Jenkinsfile|build\.gradle|settings\.gradle') {
                        [void]$candidatePaths.Add($ch.item.path.TrimStart('/'))
                    }
                }
            }
        }
    }
    # Capture the prior commit from the already-fetched Tier 2 list (avoid a second API call)
    if ($null -ne $histList -and $null -ne $histList.value -and @($histList.value).Count -gt 1) {
        $priorCommitId = $histList.value[1].commitId
    }
    Write-Host "[INFO] Tier 2 (last 5 branch commits): $($candidatePaths.Count) candidate(s)."

    # ── TIER 3: Directory-scoped repo scan ────────────────────────────────
    # Rather than scanning every script file in the entire repo (which produced
    # 188 candidates), we scope the scan to directories that Tiers 1+2 already
    # identified as relevant. If a failure is in Subway/cicd/NA/, we scan that
    # directory tree — not unrelated EMEA or Germany trees.
    # Build the set of directories that already have candidates:
    $activeDirs = [System.Collections.Generic.HashSet[string]]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($cp in $candidatePaths) {
        $d = ($cp -replace '[^/\\]+$', '').TrimEnd('/\')
        while (-not [string]::IsNullOrEmpty($d)) {
            [void]$activeDirs.Add($d)
            $d = ($d -replace '[^/\\]+$', '').TrimEnd('/\')
        }
    }
    $treeUrl = "$collectionUri$teamProject/_apis/git/repositories/$repoId/items" +
               "?recursionLevel=Full" +
               "&versionDescriptor.version=$([uri]::EscapeDataString($cleanFailedBranch))" +
               "&versionDescriptor.versionType=branch&api-version=7.1"
    $repoTree = Invoke-ADORestMethod -Uri $treeUrl
    if ($null -ne $repoTree -and $null -ne $repoTree.value) {
        $scriptPattern  = '(?i)\.(sh|ps1|rb|py|js|jsx|ts|tsx|yml|yaml|java|cs|vb|fs|go|kt|kts|swift|php|json|xml|gradle|pro|csproj|tf|tfvars|groovy|toml|rs)$|\b(?:Fastfile|Podfile|Gemfile|Dockerfile|Jenkinsfile|build\.gradle|settings\.gradle|AndroidManifest\.xml)\b'
        $excludePattern = '(?i)^(?:Pods|vendor|node_modules|DerivedData|Carthage|\.git|build|Packages|test|spec|__tests__|\.azuredevops)/' +
                          '|(?:minitest|mock\.|\.pre-commit|package-lock|yarn\.lock|Cartfile\.resolved)' +
                          '|\.min\.(js|ts)$'
        foreach ($item in $repoTree.value) {
            if ($item.gitObjectType -ne 'blob') { continue }
            $itemPath = $item.path.TrimStart('/')
            if ($itemPath -notmatch $scriptPattern)  { continue }
            if ($itemPath -match $excludePattern)     { continue }
            # Only add if it lives in a directory already flagged as relevant.
            $itemDir = ($itemPath -replace '[^/\\]+$', '').TrimEnd('/\')
            if ($activeDirs.Count -gt 0 -and -not $activeDirs.Contains($itemDir)) { continue }
            [void]$candidatePaths.Add($itemPath)
        }
    }
    Write-Host "[INFO] Tier 3 (directory-scoped scan): $($candidatePaths.Count) total candidate(s)."

    Write-Host "[INFO] $($candidatePaths.Count) candidate file(s). Prior commit: $priorCommitId"

    # ──────────────────────────────────────────────────────────────────
    #  THE LOOP: for each file, fix-and-recheck until the parser passes
    # ──────────────────────────────────────────────────────────────────
    $MAX_ITERS_PER_FILE = 25

    # DYNAMIC AI CALL CEILING (replaces the old fixed value of 25).
    # CONFIRMED VIA REAL TEST RUNS THIS SESSION: a genuinely-fixed file
    # costs roughly 1.5 AI calls on average -- most cost exactly 1 (a single
    # fix accepted immediately), some cost 2 (an initial fix plus a
    # semantic-review pass, or one retry after a rejected fix). A fixed
    # ceiling of 25 works fine for a typical real-world build failure (which
    # usually breaks a handful of files), but was confirmed too low for a
    # genuinely large multi-file event (e.g. a 40+ file test/stress run, or
    # a real incident touching many files at once) -- runs were stopping
    # partway through with files still unprocessed, even though the budget
    # itself was the limiting factor, not anything wrong with those files.
    # Scaling the ceiling to the actual candidate count fixes this without
    # removing the cost guard itself: a run with few candidates still gets a
    # small, safe budget; a run with many candidates gets a proportionally
    # larger one, capped so a candidate-detection bug can never translate
    # into unbounded spend.
    #
    # MIN_AI_CALL_CEILING (10): even a single-file run should have enough
    # budget for a fix attempt plus a semantic-review pass plus one retry,
    # without an artificially tight floor cutting that short.
    # MAX_AI_CALL_CEILING (150): hard upper bound regardless of candidate
    # count -- protects against runaway cost if Tier 1-3 candidate
    # detection ever over-broadens (e.g. an unusually large commit touching
    # hundreds of files) on a single run.
    # AI_CALLS_PER_CANDIDATE (1.5): the empirically-confirmed ratio above,
    # rounded up per-file via [Math]::Ceiling so partial-file fractions
    # never round down to less than what a single file might genuinely need.
    $MIN_AI_CALL_CEILING    = 10
    $MAX_AI_CALL_CEILING    = 150
    $AI_CALLS_PER_CANDIDATE = 1.5
    $dynamicCeiling = [Math]::Ceiling($candidatePaths.Count * $AI_CALLS_PER_CANDIDATE)
    $MAX_TOTAL_AI_CALLS = [Math]::Max($MIN_AI_CALL_CEILING, [Math]::Min($MAX_AI_CALL_CEILING, $dynamicCeiling))
    Write-Host "[INFO] AI call ceiling: $MAX_TOTAL_AI_CALLS (dynamic, based on $($candidatePaths.Count) candidate file(s) at $AI_CALLS_PER_CANDIDATE calls/file, bounded [$MIN_AI_CALL_CEILING, $MAX_AI_CALL_CEILING])"

    $script:aiCallCount = 0
    $script:aiCache     = @{}        # cache: errorSignature -> fix (avoid duplicate calls)

    # ── SEVERITY / PREVENTION-TIP CARRY-THROUGH ───────────────────────────
    # Get-AIFixes's RETURN VALUE is a plain array of fix objects, and several
    # call sites already depend on that exact shape (.Count, Where-Object,
    # etc.) -- changing it to a wrapper object would risk breaking working
    # code for a purely additive feature. Instead, severity/prevention_tip
    # are stashed here, keyed by file path, and read by the main loop AFTER
    # calling Get-AIFixes. Deliberately script-scope (not a return value) so
    # this is fully opt-in: nothing breaks if a caller never reads these.
    $script:fileSeverity      = @{}   # filePath -> "critical"|"high"|"medium"|"low"
    $script:filePreventionTip = @{}   # filePath -> single-sentence tip string

    # ── CROSS-RUN FIX MEMORY: state + LOAD ────────────────────────────────
    # Persisted across runs as a pipeline artifact ('ai-fix-memory').
    # ENHANCEMENTS: TTL eviction (90-day stale check), cross-pipeline
    # shared search (searches ALL definitions not just current), and
    # timestamps (created/lastUsed) on every entry.
    $script:fixMemory  = @{}   # signature -> @{ fixes; fails; hits; created; lastUsed }
    $script:memServed  = @{}   # filePath  -> signature served this run
    $script:memLearn   = @{}   # filePath  -> @{ Sig; Fixes } staged this run
    $script:memStats   = @{ hits=0; misses=0; ttlEvicted=0; newEntries=0 }  # analytics
    $now = [datetime]::UtcNow
    try {
        if (-not [string]::IsNullOrWhiteSpace($collectionUri)) {
            # Cross-pipeline: search ALL recent builds (not just current definition)
            # so fixes learned in the iOS pipeline benefit the web pipeline and vice-versa
            $buildsUri = "$collectionUri$teamProject/_apis/build/builds?statusFilter=completed&resultFilter=succeeded&queryOrder=finishTimeDescending&`$top=30&api-version=7.1"
            $recent = Invoke-ADORestMethod -Uri $buildsUri
            $loadedCount = 0
            if ($null -ne $recent -and $null -ne $recent.value) {
                foreach ($b in @($recent.value)) {
                    if ("$($b.id)" -eq "$buildId") { continue }
                    $artUri = "$collectionUri$teamProject/_apis/build/builds/$($b.id)/artifacts?artifactName=ai-fix-memory&api-version=7.1"
                    $art = Invoke-ADORestMethod -Uri $artUri
                    $dl = $null
                    if ($null -ne $art -and $null -ne $art.resource) { $dl = $art.resource.downloadUrl }
                    if ([string]::IsNullOrWhiteSpace($dl)) { continue }
                    $memZip = Join-Path $env:AGENT_TEMPDIRECTORY "aimem_$($b.id).zip"
                    $memOut = Join-Path $env:AGENT_TEMPDIRECTORY "aimem_$($b.id)"
                    Invoke-WebRequest -Uri $dl -Headers @{ Authorization = "Basic $auth" } -OutFile $memZip -TimeoutSec 60 -ErrorAction Stop
                    if (Test-Path $memOut) { Remove-Item $memOut -Recurse -Force -EA SilentlyContinue }
                    Expand-Archive -Path $memZip -DestinationPath $memOut -Force -ErrorAction Stop
                    $memFile = Get-ChildItem -Path $memOut -Recurse -Filter "fix_memory.json" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($null -ne $memFile) {
                        try {
                            $loaded = (Get-Content $memFile.FullName -Raw -EA Stop) | ConvertFrom-Json -ErrorAction Stop
                            foreach ($p in $loaded.PSObject.Properties) {
                                if ($script:fixMemory.ContainsKey($p.Name)) { continue }
                                $created  = if ($p.Value.created)  { try { [datetime]$p.Value.created  } catch { $now.AddDays(-1) } } else { $now.AddDays(-1) }
                                $lastUsed = if ($p.Value.lastUsed) { try { [datetime]$p.Value.lastUsed } catch { $now.AddDays(-1) } } else { $now.AddDays(-1) }
                                $ageLastUsed = ($now - $lastUsed).TotalDays
                                if ($ageLastUsed -gt 90 -and [int]$p.Value.hits -lt 3) {
                                    $script:memStats.ttlEvicted++
                                    Write-Host "[Memory] TTL evicted: $($p.Name) (last used $([int]$ageLastUsed)d ago, hits=$($p.Value.hits))"
                                    continue
                                }
                                $script:fixMemory[$p.Name] = @{
                                    fixes    = @($p.Value.fixes)
                                    fails    = [int]$p.Value.fails
                                    hits     = [int]$p.Value.hits
                                    created  = $created.ToString('yyyy-MM-dd')
                                    lastUsed = $lastUsed.ToString('yyyy-MM-dd')
                                }
                                $loadedCount++
                            }
                            Write-Host "[INFO] 🧠 Merged fix-memory from build $($b.id) (pipeline $($b.definition.id)): $loadedCount signature(s) total."
                        } catch {
                            Write-Host "[WARN] Could not load fix-memory from build $($b.id): $($_.Exception.Message)"
                        }
                    }
                    # IMP-5: Break after first build that actually contained signatures.
                    # Cross-pipeline sharing is achieved by the broad search across all definitions.
                    # Continuing past the first valid artifact adds API calls but little value —
                    # the most recent build has the most up-to-date merged memory.
                    if ($loadedCount -gt 0) { break }
                }
            }
            Write-Host "[INFO] 🧠 Fix-memory ready: $($script:fixMemory.Count) signature(s) across all pipelines."

            # ── OPT-IN HISTORICAL TELEMETRY: cumulative top-error report ──────
            # Deliberately NOT run on every triage invocation -- gated behind an
            # explicit env var so this reporting pass never slows down the hot
            # path (fixing TODAY's failure). Intended to be set by a separate,
            # low-frequency pipeline job (e.g. a nightly/weekly schedule), not
            # by the normal per-build trigger. Reuses the same proven artifact-
            # fetch mechanism as the cache-warming loop just above (confirmed
            # real: that loop already successfully queries an artifact literally
            # named "ai-fix-memory", so the publish side of this is established),
            # but does NOT share its early-exit-on-first-hit behavior -- this
            # pass exists specifically to look BACK across many builds and
            # aggregate, not to warm a live cache as fast as possible.
            if ($env:AI_TRIAGE_GENERATE_REPORT -eq 'true') {
                Write-Host "[INFO] 📊 AI_TRIAGE_GENERATE_REPORT=true — running historical aggregation pass."
                $sigOccurrences = @{}   # signature -> @{ TotalHits; TotalFails; SeenInBuilds; FirstSeen; LastSeen }
                $reportBuildsScanned = 0
                $reportMaxBuilds = 10   # smaller than the 30 used for cache warm-up -- this is reporting, not active remediation
                try {
                    if (-not [string]::IsNullOrWhiteSpace($collectionUri)) {
                        $reportBuildsUri = "$collectionUri$teamProject/_apis/build/builds?statusFilter=completed&resultFilter=succeeded&queryOrder=finishTimeDescending&`$top=$reportMaxBuilds&api-version=7.1"
                        $reportRecent = Invoke-ADORestMethod -Uri $reportBuildsUri
                        if ($null -ne $reportRecent -and $null -ne $reportRecent.value) {
                            foreach ($rb in @($reportRecent.value)) {
                                $rArtUri = "$collectionUri$teamProject/_apis/build/builds/$($rb.id)/artifacts?artifactName=ai-fix-memory&api-version=7.1"
                                $rArt = Invoke-ADORestMethod -Uri $rArtUri
                                $rDl = $null
                                if ($null -ne $rArt -and $null -ne $rArt.resource) { $rDl = $rArt.resource.downloadUrl }
                                if ([string]::IsNullOrWhiteSpace($rDl)) { continue }
                                $rZip = Join-Path $env:AGENT_TEMPDIRECTORY "aireport_$($rb.id).zip"
                                $rOut = Join-Path $env:AGENT_TEMPDIRECTORY "aireport_$($rb.id)"
                                try {
                                    Invoke-WebRequest -Uri $rDl -Headers @{ Authorization = "Basic $auth" } -OutFile $rZip -TimeoutSec 60 -ErrorAction Stop
                                    if (Test-Path $rOut) { Remove-Item $rOut -Recurse -Force -EA SilentlyContinue }
                                    Expand-Archive -Path $rZip -DestinationPath $rOut -Force -ErrorAction Stop
                                    $rMemFile = Get-ChildItem -Path $rOut -Recurse -Filter "fix_memory.json" -ErrorAction SilentlyContinue | Select-Object -First 1
                                    if ($null -ne $rMemFile) {
                                        $rLoaded = (Get-Content $rMemFile.FullName -Raw -EA Stop) | ConvertFrom-Json -ErrorAction Stop
                                        foreach ($rp in $rLoaded.PSObject.Properties) {
                                            if (-not $sigOccurrences.ContainsKey($rp.Name)) {
                                                $sigOccurrences[$rp.Name] = @{ TotalHits=0; TotalFails=0; SeenInBuilds=0; FirstSeen=$rb.id; LastSeen=$rb.id }
                                            }
                                            $sigOccurrences[$rp.Name].TotalHits  += [int]$rp.Value.hits
                                            $sigOccurrences[$rp.Name].TotalFails += [int]$rp.Value.fails
                                            $sigOccurrences[$rp.Name].SeenInBuilds++
                                            $sigOccurrences[$rp.Name].LastSeen = $rb.id   # most recent build wins, since we scan newest-first
                                        }
                                        $reportBuildsScanned++
                                    }
                                } catch {
                                    Write-Host "[WARN] Report pass: could not load fix-memory from build $($rb.id): $($_.Exception.Message)"
                                } finally {
                                    Remove-Item $rZip -Force -EA SilentlyContinue
                                    if (Test-Path $rOut) { Remove-Item $rOut -Recurse -Force -EA SilentlyContinue }
                                }
                            }
                        }
                    }
                    $topErrors = @(
                        $sigOccurrences.GetEnumerator() |
                        Sort-Object { [int]$_.Value.TotalHits } -Descending |
                        Select-Object -First 10 |
                        ForEach-Object { @{ sig=$_.Key; total_hits=[int]$_.Value.TotalHits; total_fails=[int]$_.Value.TotalFails; seen_in_builds=[int]$_.Value.SeenInBuilds; last_seen_build=$_.Value.LastSeen } }
                    )
                    $reportObj = @{
                        generated_utc        = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
                        builds_scanned       = $reportBuildsScanned
                        unique_signatures    = $sigOccurrences.Count
                        top_10_errors        = $topErrors
                    }
                    $reportDir = Join-Path $env:AGENT_TEMPDIRECTORY "AIMemory"
                    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
                    $reportPath = Join-Path $reportDir "top_errors_report.json"
                    Set-Content -Path $reportPath -Value ($reportObj | ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8
                    Write-Host "##vso[task.setvariable variable=AiTopErrorsReportPath;isOutput=true]$reportPath"
                    Write-Host "[INFO] 📊 Top-errors report written: $reportBuildsScanned build(s) scanned, $($sigOccurrences.Count) unique signature(s), top hit count: $(if ($topErrors.Count -gt 0) { $topErrors[0].total_hits } else { 0 })"
                } catch {
                    Write-Host "[WARN] Historical report pass failed: $($_.Exception.Message)"
                }
            }
        }
    } catch {
        $script:fixMemory = @{}
        Write-Host "[INFO] Fix-memory load skipped ($($_.Exception.Message)). Proceeding without it."
    }
    # allFixes may already contain bundler fixes added earlier (before Tier 0-3 discovery).
    # Only initialize here if not already created — preserves pre-loop fixes.
    if ($null -eq $allFixes) { $allFixes = [System.Collections.Generic.List[object]]::new() }
    $fileStatus = [System.Collections.Generic.List[string]]::new()

    function Get-FileFromCommit {
        param([string]$path, [string]$commit)
        if ([string]::IsNullOrWhiteSpace($commit)) { return $null }
        $u = "$collectionUri$teamProject/_apis/git/repositories/$repoId/items?path=$([uri]::EscapeDataString($path))&versionDescriptor.version=$commit&versionDescriptor.versionType=commit&api-version=7.1"
        return Invoke-ADORestMethod -Uri $u
    }

    function Add-LineNumbers {
        param([string]$content)
        $n = 0
        return (($content -split "\r?\n" | ForEach-Object { $n++; "{0,4}: {1}" -f $n, $_ }) -join "`n")
    }

    # SECURITY: redact secret VALUES before any content leaves the agent for Gemini.
    # We replace only the value (not the whole line) so line numbers and structure are
    # preserved for old_code matching. The AI sees [REDACTED_*] placeholders, never secrets.
    function Protect-Secrets {
        param([string]$txt)
        if ([string]::IsNullOrEmpty($txt)) { return $txt }
        return $txt `
            -replace '(?s)-----BEGIN[^-]*-----.*?-----END[^-]*-----', '[REDACTED_KEY_BLOCK]' `
            -replace '(?im)((?:password|passwd|secret|token|pat|apikey|api_key|access_key|client_secret|private_key|connectionstring|conn_str)\s*[:=]\s*["'']?)(?!\$\()([^"''\s]{4,})', '$1[REDACTED_SECRET]' `
            -replace '(?i)(ey[a-zA-Z0-9_-]{8,}\.[a-zA-Z0-9_-]{8,}\.[a-zA-Z0-9_-]{8,})', '[REDACTED_JWT]' `
            -replace '(?i)(Bearer\s+)[a-zA-Z0-9\-\._~+/]{12,}=*', '$1[REDACTED_TOKEN]' `
            -replace 'https?://[^:/\s]+:[^@/\s]+@', 'https://[REDACTED_CREDS]@' `
            -replace '(?i)(AKIA|ASIA)[A-Z0-9]{16}', '[REDACTED_AWS_KEY]' `
            -replace '(gh[pousr]_[A-Za-z0-9]{20,})', '[REDACTED_GH_TOKEN]'
    }

    # ── DETERMINISTIC UNCLOSED-QUOTE BATCH REPAIRER ──────────────────────
    # A developer reviewing a broken file fixes ALL unclosed quotes in one pass —
    # they don't fix one, recompile, find the next, repeat. This function does the
    # same: scan every line in one pass, fix every line with an odd unescaped-quote
    # count. Returns the fully-repaired content + a list of all changes made.
    # Heredoc content is correctly skipped (quotes inside heredocs are literal).
    # For YAML inline blocks: call on the extracted block body, then map line
    # numbers back to YAML space before applying to the YAML file.
    function Repair-AllUnclosedQuotes {
        param([string]$content)
        $lineEnding = if ($content -match "\r\n") { "`r`n" } else { "`n" }
        $lines = $content -split "\r?\n"
        $fixes = [System.Collections.Generic.List[object]]::new()
        $inHeredoc = $false; $heredocEnd = ""
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]; $trimmed = $line.Trim()
            if (-not $inHeredoc) {
                if ($line -match "<<'?`"?(\w+)'?`"?") { $inHeredoc=$true; $heredocEnd=$matches[1]; continue }
            } else {
                if ($trimmed -eq $heredocEnd) { $inHeredoc=$false; $heredocEnd="" }
                continue
            }
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
            $count=0; $j=0; $inSingleQ=$false; $inDoubleQ=$false
            while ($j -lt $line.Length) {
                $c = $line[$j]
                if ($inSingleQ) {
                    # Inside single quotes: EVERYTHING is literal in bash -- no escape
                    # mechanism exists here at all, not even backslash. Only a closing
                    # ' ends this state; " and \ inside are just ordinary characters.
                    if ($c -eq "'") { $inSingleQ = $false }
                    $j++; continue
                }
                if ($j+1 -lt $line.Length -and $c -eq '\') { $j+=2; continue }
                if ($c -eq "'") {
                    if ($inDoubleQ) {
                        # A single quote has NO special meaning inside an OPEN
                        # double-quoted string -- literal character, no state change.
                        $j++; continue
                    }
                    $inSingleQ = $true; $j++; continue
                }
                if ($c -eq '"') { $count++; $inDoubleQ = -not $inDoubleQ; $j++; continue }
                $j++
            }
            if ($count % 2 -eq 1) {
                $fixed = $line + '"'
                $fixes.Add([PSCustomObject]@{ BlockLine=$i+1; OriginalLine=$line; FixedLine=$fixed })
                $lines[$i] = $fixed
            }
        }
        return @{ Content = ($lines -join $lineEnding); Fixes = $fixes }
    }

    # ── DETERMINISTIC UNCLOSED-SUBSTITUTION + BRACE REPAIRER ────────────────
    # Companion to Repair-AllUnclosedQuotes. Handles TWO separate bash error classes:
    #
    #  1. "unexpected EOF while looking for matching ')'"
    #     → $( command substitution opened but not closed on this line
    #     → e.g.  PROP_VALUE=$(defaults read "$INFO_PLIST_FILE" "$PROP_KEY"
    #
    #  2. "bad substitution" / "syntax error"
    #     → ${ variable expansion opened but } not closed on this line
    #     → e.g.  echo "version: ${BUILD_VERSION"    (missing closing })
    #
    # Strategy: walk each non-comment, non-heredoc line character by character,
    # tracking TWO independent depth counters:
    #   parenDepth — for $( ... )
    #   braceDepth — for ${ ... }
    # Skip single-quoted strings ('...' is literal in bash — no expansion inside '').
    # At end-of-line: append ')' × parenDepth then '}' × braceDepth.
    #
    # Returns the SAME @{ Content; Fixes } structure as Repair-AllUnclosedQuotes.
    function Repair-AllUnclosedSubstitutions {
        param([string]$content)
        $lineEnding = if ($content -match "\r\n") { "`r`n" } else { "`n" }
        $lines = $content -split "\r?\n"
        $fixes = [System.Collections.Generic.List[object]]::new()
        $inHeredoc = $false; $heredocEnd = ""

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]; $trimmed = $line.Trim()

            if (-not $inHeredoc) {
                if ($line -match "<<[-]?'?`"?(\w+)'?`"?") { $inHeredoc = $true; $heredocEnd = $matches[1]; continue }
            } else {
                if ($trimmed -eq $heredocEnd) { $inHeredoc = $false; $heredocEnd = "" }
                continue
            }

            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }

            $parenDepth = 0   # tracks $( ... )
            $braceDepth = 0   # tracks ${ ... }
            $inSQ = $false
            $k = 0

            while ($k -lt $line.Length) {
                $ch = $line[$k]

                if ($ch -eq '\' -and -not $inSQ)    { $k += 2; continue }
                if ($ch -eq "'")                     { $inSQ = -not $inSQ; $k++; continue }
                if ($inSQ)                           { $k++; continue }

                if ($ch -eq '$' -and ($k + 1) -lt $line.Length) {
                    $nxt = $line[$k + 1]
                    if ($nxt -eq '(') { $parenDepth++; $k += 2; continue }
                    if ($nxt -eq '{') { $braceDepth++; $k += 2; continue }
                }

                if ($ch -eq ')' -and $parenDepth -gt 0) { $parenDepth-- }
                if ($ch -eq '}' -and $braceDepth -gt 0) { $braceDepth-- }

                $k++
            }

            if ($parenDepth -gt 0 -or $braceDepth -gt 0) {
                $fixedLine = $line
                if ($parenDepth -gt 0) { $fixedLine = $fixedLine + (')' * $parenDepth) }
                if ($braceDepth  -gt 0) { $fixedLine = $fixedLine + ('}' * $braceDepth) }
                $fixes.Add([PSCustomObject]@{ BlockLine = $i + 1; OriginalLine = $line; FixedLine = $fixedLine })
                $lines[$i] = $fixedLine
            }
        }

        return @{ Content = ($lines -join $lineEnding); Fixes = $fixes }
    }

    # ── COMBINED DELIMITER REPAIRER ──────────────────────────────────────────
    # Fixes unclosed " quotes, $( command substitutions, AND ${ variable braces
    # all in ONE pass — generating exactly ONE fix per line.
    #
    # CLOSER ORDER RULE — LIFO (Last In First Out):
    #   Track the character position where each $( and " was last opened.
    #   Whichever was opened LAST must be closed FIRST.
    #
    #   Pattern A — "  opens BEFORE $(  (paren is INSIDE string):
    #     e.g. echo "$(cmd arg     → close ) first then " → )"
    #
    #   Pattern B — $( opens BEFORE "  (quote is an arg INSIDE paren):
    #     e.g. VAR=$(cmd "arg      → close " first then ) → ")
    #     CRITICAL: if ) is appended first it lands INSIDE the "..." arg
    #     and bash ignores it as a $( closer → "unexpected EOF" error
    #
    #   ${ → INSERT } right after variable name (regex, position-correct)
    function Repair-AllUnclosedDelimiters {
        param([string]$content)
        $lineEnding = if ($content -match "\r\n") { "`r`n" } else { "`n" }
        $lines = $content -split "\r?\n"
        $fixes = [System.Collections.Generic.List[object]]::new()
        $inHeredoc = $false; $heredocEnd = ""

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]; $trimmed = $line.Trim()

            if (-not $inHeredoc) {
                if ($line -match "<<[-]?'?`"?(\w+)'?`"?") { $inHeredoc = $true; $heredocEnd = $matches[1]; continue }
            } else {
                if ($trimmed -eq $heredocEnd) { $inHeredoc = $false; $heredocEnd = "" }
                continue
            }
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }

            # ── Single-pass depth + position tracking ────────────────────
            $parenDepth = 0; $braceDepth = 0; $quoteOpen = $false; $inSQ = $false; $k = 0
            $lastParenOpenPos = -1   # position of last unclosed $( opening
            $lastQuoteOpenPos = -1   # position of last currently-open " opening

            while ($k -lt $line.Length) {
                $ch = $line[$k]
                if ($ch -eq '\' -and -not $inSQ)    { $k += 2; continue }
                if ($ch -eq "'")                     { $inSQ = -not $inSQ; $k++; continue }
                if ($inSQ)                           { $k++; continue }
                if ($ch -eq '"') {
                    if ($quoteOpen) {
                        $quoteOpen = $false; $lastQuoteOpenPos = -1  # closed
                    } else {
                        $quoteOpen = $true;  $lastQuoteOpenPos = $k  # opened — record position
                    }
                    $k++; continue
                }
                if ($ch -eq '$' -and ($k+1) -lt $line.Length) {
                    if ($line[$k+1] -eq '(') { $parenDepth++; $lastParenOpenPos = $k; $k += 2; continue }
                    if ($line[$k+1] -eq '{') { $braceDepth++;                          $k += 2; continue }
                }
                if ($ch -eq ')' -and $parenDepth -gt 0) {
                    $parenDepth--
                    if ($parenDepth -eq 0) { $lastParenOpenPos = -1 }
                }
                if ($ch -eq '}' -and $braceDepth -gt 0) { $braceDepth-- }
                $k++
            }

            if ($parenDepth -gt 0 -or $braceDepth -gt 0 -or $quoteOpen) {
                $fixedLine = $line

                # Step 1: ${ — INSERT } right after the variable name.
                # Manual character scan rather than [regex]::Replace(...) with an inline
                # scriptblock-as-MatchEvaluator — see Test-CssSyntax above for the same
                # reasoning: the inline scriptblock-to-delegate conversion form is not
                # confirmed reliable across every PowerShell version/edition this engine
                # may run under, and a plain character pass needs no delegate at all.
                # Correctly positions } even when ) or " follow the variable name, and
                # correctly leaves an ALREADY-closed ${...} untouched.
                if ($braceDepth -gt 0) {
                    $sb2 = [System.Text.StringBuilder]::new()
                    $bi = 0; $bn = $fixedLine.Length
                    while ($bi -lt $bn) {
                        if ($fixedLine[$bi] -eq '$' -and ($bi+1) -lt $bn -and $fixedLine[$bi+1] -eq '{') {
                            $nameStart = $bi + 2
                            $bj = $nameStart
                            if ($bj -lt $bn -and ($fixedLine[$bj] -match '[A-Za-z_#!?@*]')) {
                                if ($fixedLine[$bj] -match '[#!?@*]') {
                                    $bj++   # special single-char variable name — no further chars
                                } else {
                                    $bj++
                                    while ($bj -lt $bn -and ($fixedLine[$bj] -match '[A-Za-z0-9_]')) { $bj++ }
                                }
                                $varName = $fixedLine.Substring($nameStart, $bj - $nameStart)
                                if ($bj -lt $bn -and $fixedLine[$bj] -eq '}') {
                                    # Already closed — copy through unchanged, including the }.
                                    [void]$sb2.Append($fixedLine.Substring($bi, ($bj - $bi) + 1))
                                    $bi = $bj + 1; continue
                                }
                                # Not closed — insert '}' right after the name.
                                [void]$sb2.Append('${').Append($varName).Append('}')
                                $bi = $bj; continue
                            }
                        }
                        [void]$sb2.Append($fixedLine[$bi]); $bi++
                    }
                    $fixedLine = $sb2.ToString()
                }

                # Steps 2+3: $( and " — LIFO ordering based on which opened last.
                # If both are unclosed:
                #   lastQuoteOpenPos > lastParenOpenPos → " opened LAST (inside $() → close " first, then )
                #   lastParenOpenPos > lastQuoteOpenPos → $( opened LAST (inside "...") → close ) first, then "
                if ($parenDepth -gt 0 -and $quoteOpen) {
                    if ($lastQuoteOpenPos -gt $lastParenOpenPos) {
                        # Pattern B: $(cmd "arg — " is innermost → close " then )
                        $fixedLine = $fixedLine + '"' + (')' * $parenDepth)
                    } else {
                        # Pattern A: "$(cmd arg — $( is innermost → close ) then "
                        $fixedLine = $fixedLine + (')' * $parenDepth) + '"'
                    }
                } elseif ($parenDepth -gt 0) {
                    $fixedLine = $fixedLine + (')' * $parenDepth)
                } elseif ($quoteOpen) {
                    $fixedLine = $fixedLine + '"'
                }

                if ($fixedLine -ne $line) {
                    $what = @()
                    if ($braceDepth -gt 0) { $what += 'unclosed ${' }
                    if ($parenDepth -gt 0) { $what += 'unclosed $(' }
                    if ($quoteOpen)         { $what += 'unclosed "' }
                    $fixes.Add([PSCustomObject]@{
                        BlockLine    = $i + 1
                        OriginalLine = $line
                        FixedLine    = $fixedLine
                        Title        = "Fix $($what -join ' + ') (det-scan)"
                    })
                    $lines[$i] = $fixedLine
                }
            }
        }
        return @{ Content = ($lines -join $lineEnding); Fixes = $fixes }
    }

    function Apply-FixByLine {
        param([string]$content, [int]$lineNumber, [string]$newCode, [string]$filePath = '')
        # Detect and preserve the original line-ending style (CRLF vs LF) so
        # we don't accidentally alter trailing newlines or blank lines in the file.
        $lineEnding = if ($content -match "\r\n") { "`r`n" } else { "`n" }
        $lines = $content -split "\r?\n"
        if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) { return @{ Applied = $false } }
        $idx = $lineNumber - 1
        $oldLine = $lines[$idx]
        $indent = ($oldLine -replace "^(\s*).*","`$1")
        $newTrim = $newCode.Trim()
        # If the AI returned a REDACTED placeholder it means our Protect-Secrets
        # redacted a value that shouldn't have been (e.g. a non-ADO-macro secret).
        # Keep the TODO so the developer knows to fill it in manually.
        # BUGFIX: the replacement is a comment, and '#' is only a valid comment
        # marker in some languages (bash, Python, Ruby, YAML, PowerShell). For
        # CSS/SCSS/LESS, SQL, and HTML — all added later — a bare '#' is NOT a
        # comment and would itself be a new syntax error dropped into the file.
        # Protect-Secrets runs unconditionally on every file regardless of
        # extension, so this is a real, reachable path, not a hypothetical one.
        if ($newTrim -match '\[REDACTED_(SECRET|JWT|TOKEN|KEY_BLOCK|AWS_KEY|GH_TOKEN|CREDS)\]') {
            $todoComment = if ($filePath -match '\.(css|scss|less|sass)$') { '/* TODO: INSERT_ACTUAL_VALUE_HERE */' }
                           elseif ($filePath -match '\.sql$') { '-- TODO: INSERT_ACTUAL_VALUE_HERE' }
                           elseif ($filePath -match '\.html?$') { '<!-- TODO: INSERT_ACTUAL_VALUE_HERE -->' }
                           else { '# TODO: INSERT_ACTUAL_VALUE_HERE' }   # unchanged default for every other language
            $newTrim = $newTrim -replace '\[REDACTED_(?:SECRET|JWT|TOKEN|KEY_BLOCK|AWS_KEY|GH_TOKEN|CREDS)\]', $todoComment
        }
        $newLine = $indent + $newTrim
        $lines[$idx] = $newLine
        return @{ Applied = $true; Content = ($lines -join $lineEnding); OldLine = $oldLine; NewLine = $newLine }
    }

    # ── SEMANTIC FALLBACK REVIEW ─────────────────────────────────────────
    # BUGFIX: Get-SyntaxError returns Ok=$true whenever Test-StructuralSyntax
    # (brace/paren/bracket balance only) was used as a substitute for a real
    # compiler/linter that wasn't available on this agent (no tsc, no javac,
    # no dotnet, no kotlinc, no rustc, no php, no swiftc, no groovyc, no
    # gofmt, no dart, no vue-tsc — see the Fallback=$true markers next to
    # each Test-StructuralSyntax / Test-VueSyntax call site above). A file
    # can be PERFECTLY brace-balanced and still contain real bugs a real
    # compiler would catch — wrong types, undefined symbols, typos in API
    # calls, logic errors. Previously, Ok=$true (regardless of HOW it was
    # determined) caused the file to be marked clean and skipped entirely —
    # the AI semantic review (Get-AIFixes) was never invoked for it.
    #
    # This function runs exactly ONE semantic AI pass for such files: it
    # does NOT claim a parser error occurred (that would be a lie to the AI
    # and would invite hallucinated "fixes" for a file that genuinely has no
    # reported error) — instead it asks the AI to do a real code review for
    # bugs a structural-only check cannot see. Any fixes returned are run
    # through the EXACT SAME safety pipeline as the main repair loop
    # (Apply-FixByLine, YAML structural-key / metadata guards, no-op
    # rejection) so nothing here bypasses the existing verification.
    #
    # Deliberately a SINGLE pass, not an iterate-to-convergence loop like the
    # main syntax-fix loop: there is no parser error signature to converge
    # against here, so looping would have no stopping condition other than
    # the AI simply returning nothing.
    function Invoke-SemanticFallbackReview {
        param([string]$path, [string]$content, [string]$prior)

        # ── INPUT GUARDS ──────────────────────────────────────────────────
        # Defensive: every other risk-bearing function in this file guards
        # its own inputs before doing real work. $content empty/whitespace
        # means there is nothing to review; $path empty means any fix we
        # generated could not be attributed back to a real file anyway.
        if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($content)) {
            return $content
        }

        if ($script:aiCallCount -ge $MAX_TOTAL_AI_CALLS) {
            Write-Host "  ⓘ ${path}: skipping semantic fallback review — global AI call ceiling reached."
            return $content
        }

        # ── EXCEPTION SAFETY ────────────────────────────────────────────────
        # This is the newest, least battle-tested code path in the engine.
        # A thrown exception anywhere below (AI call edge case, JSON/regex
        # edge case) must NOT abort the entire run — the script has only
        # ONE top-level try/catch (around the whole script body), so any
        # uncaught exception here would stop processing every remaining
        # file, not just this one. Degrade to "no semantic changes" and
        # let the file proceed with whatever it already had (structurally
        # clean) rather than risk the whole pipeline run.
        try {
            Write-Host "  🔎 ${path}: structurally clean via fallback check (real compiler/linter unavailable) — running one semantic AI review pass."

            $numberedFull = Add-LineNumbers -content (Protect-Secrets $content)
            $semanticNote = "No structural parser error was found in this file (braces/parens/brackets all balance). " +
                            "However, the real compiler/linter for this language was NOT available on this build agent, " +
                            "so only a structural check ran -- semantic correctness has NOT yet been verified. " +
                            "Review the whole file as a senior developer would in code review: undefined or " +
                            "misspelled identifiers, wrong types, incorrect API usage, logic errors, missing " +
                            "null/error handling, and any other real bug a compiler or linter would normally catch. " +
                            "If the file genuinely has no issues, return an empty fixes array -- do NOT invent changes " +
                            "to lines that are already correct."

            $semanticFixes = Get-AIFixes -filePath $path -numberedContent $numberedFull -parserError $semanticNote -errorLine 1 -priorVersion (Protect-Secrets $prior)

            if ($null -eq $semanticFixes -or $semanticFixes.Count -eq 0) {
                Write-Host "    ✅ ${path}: semantic review found no issues."
                return $content
            }

            $working = $content
            $sortedSemanticFixes = $semanticFixes | Where-Object { $null -ne $_.line_number -and $null -ne $_.new_code } |
                                   Sort-Object { [int]$_.line_number }
            $appliedCount = 0
            foreach ($fix in $sortedSemanticFixes) {
                [int]$targetLine = 0
                if (-not [int]::TryParse([string]$fix.line_number, [ref]$targetLine) -or $targetLine -lt 1) { continue }

                $newCodeTrimmed = ([string]$fix.new_code).Trim()
                $isYamlStructure = ($newCodeTrimmed -match '(?i)^(?:steps|jobs|stages|trigger|resources|variables|parameters|pool|extends|pr|schedules)\s*:\s*$')
                if ($isYamlStructure) {
                    Write-Host "    ⚠️ Rejected hallucinated structural fix at line $targetLine (semantic review): '$newCodeTrimmed'"
                    continue
                }

                $lineArr = $working -split "\r?\n"
                if ($targetLine -le $lineArr.Count) {
                    $origLine = $lineArr[$targetLine - 1]
                    $isYamlMeta = ($origLine.Trim() -match '(?i)^(?:task|displayName|inputs|condition|env|name|dependsOn|timeoutInMinutes|continueOnError|enabled|pool|uses)\s*:')
                    if ($isYamlMeta) {
                        Write-Host "    ⚠️ Rejected semantic-review fix to YAML metadata line $targetLine : '$($origLine.Trim())'"
                        continue
                    }
                }

                $applied = Apply-FixByLine -content $working -lineNumber $targetLine -newCode $fix.new_code -filePath $path
                if (-not $applied.Applied) { continue }
                # BUGFIX: same fix as the main no-op check above -- leading
                # whitespace must be compared EXACTLY, not collapsed, so a
                # genuine leading-tab-vs-spaces fix is never mistaken for a
                # no-op. See the detailed comment on the main check for the
                # real incident this was found from.
                $oldLeadMatch = [regex]::Match($applied.OldLine, '^([ \t]*)(.*)$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
                $newLeadMatch = [regex]::Match($applied.NewLine, '^([ \t]*)(.*)$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
                $oldLeading = $oldLeadMatch.Groups[1].Value; $oldRest = $oldLeadMatch.Groups[2].Value
                $newLeading = $newLeadMatch.Groups[1].Value; $newRest = $newLeadMatch.Groups[2].Value
                $oldRestNorm = ($oldRest -replace '\s+',' ').Trim()
                $newRestNorm = ($newRest -replace '\s+',' ').Trim()
                if (($oldLeading -eq $newLeading) -and ($oldRestNorm -eq $newRestNorm)) {
                    Write-Host "    ⚠️ Skipping no-op semantic fix at line $targetLine (old_code == new_code after normalization)"
                    continue
                }

                $working = $applied.Content
                $appliedCount++
                $allFixes.Add([PSCustomObject]@{
                    file_path = $path; line_number = $targetLine
                    title     = if ([string]::IsNullOrWhiteSpace($fix.title)) { "Semantic review fix in $([IO.Path]::GetFileName($path))" } else { "Semantic review: $($fix.title)" }
                    old_code  = $applied.OldLine; new_code = $applied.NewLine
                    confidence = if ($null -ne $fix.confidence) { $fix.confidence } else { 0.75 }
                })
                Write-Host "    ➡️ Semantic-review fix at line $targetLine : $($fix.title)"
            }
            if ($appliedCount -eq 0) {
                Write-Host "    ✅ ${path}: semantic review returned no applicable fixes."
            }
            return $working
        } catch {
            Write-Host "  ⚠️ ${path}: semantic fallback review failed unexpectedly ($($_.Exception.Message)) — skipping semantic review for this file, keeping it as structurally clean."
            return $content
        }
    }

    $script:externalFiles = [System.Collections.Generic.List[string]]::new()
    $script:cleanFiles   = [System.Collections.Generic.List[string]]::new()
    $phaseStart          = [System.Diagnostics.Stopwatch]::StartNew()

    # Use a while-loop with index (not foreach) so we can safely append new
    # template references to $pathsToProcess during iteration without throwing
    # InvalidOperationException (List<T> enumerator forbids modification).
    $pathsToProcess = [System.Collections.Generic.List[string]]::new($candidatePaths)
    $processedPaths = [System.Collections.Generic.HashSet[string]]([System.StringComparer]::OrdinalIgnoreCase)
    $procIdx = 0
    $selfExclude = '(?i)(ai-triage|ai-interactive|triage-webhook|ai-remediator)'

    # ── PARALLEL PRE-FETCH: download all file contents concurrently ──────
    # Fetching files from ADO is pure network I/O. Pre-fetching in parallel
    # before the sequential processing loop cuts the wall-clock time by 4-6×
    # on large candidate sets (60+ files). The sequential loop then uses the
    # pre-fetched cache instead of blocking on each ADO API call individually.
    $preFetchCache = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($repoProvider -eq 'TfsGit' -and $pathsToProcess.Count -gt 0) {
        Write-Host "[INFO] ⚡ Pre-fetching $($pathsToProcess.Count) file(s) in parallel (throttle: 8)..."
        $preFetchStart = [System.Diagnostics.Stopwatch]::StartNew()
        $pathsToProcess | ForEach-Object -Parallel {
            $p = $_; $sv = $using:sourceVersion
            $cu = $using:collectionUri; $tp = $using:teamProject; $ri = $using:repoId; $au = $using:auth
            $se = $using:selfExclude; $cache = $using:preFetchCache
            if ($p -match $se) { return }
            try {
                $u = "$cu$tp/_apis/git/repositories/$ri/items?path=$([uri]::EscapeDataString($p))&versionDescriptor.version=$sv&versionDescriptor.versionType=commit&api-version=7.1"
                $r = Invoke-RestMethod -Uri $u -Headers @{ Authorization = "Basic $au" } -ContentType "application/json" -TimeoutSec 30 -EA Stop
                if (-not [string]::IsNullOrWhiteSpace($r)) { $null = $cache.TryAdd($p, $r) }
            } catch { }
        } -ThrottleLimit 8
        Write-Host "[INFO] ⚡ Pre-fetch complete in $([int]$preFetchStart.Elapsed.TotalSeconds)s — $($preFetchCache.Count) file(s) cached."

        # Override Get-FileFromCommit to use cache when available
        function Get-FileFromCommit {
            param([string]$path, [string]$commit)
            $cached = $null
            if ($preFetchCache.TryGetValue($path, [ref]$cached)) { return $cached }
            # Cache miss (e.g. dynamically added path): fall through to original
            if ([string]::IsNullOrWhiteSpace($commit)) { return $null }
            $u = "$collectionUri$teamProject/_apis/git/repositories/$repoId/items?path=$([uri]::EscapeDataString($path))&versionDescriptor.version=$commit&versionDescriptor.versionType=commit&api-version=7.1"
            return Invoke-ADORestMethod -Uri $u
        }
    }

    while ($procIdx -lt $pathsToProcess.Count) {
        $path = $pathsToProcess[$procIdx]; $procIdx++
        # HashSet.Add() returns true = newly added, false = already processed. Skip duplicates.
        if (-not $processedPaths.Add($path)) { continue }
        # Skip AI infrastructure files — the triage must not self-repair
        if ($path -match $selfExclude) { Write-Host "[INFO] Skipping AI infrastructure file: $path"; continue }
        if ($repoProvider -ne 'TfsGit') { break }
        $original = Get-FileFromCommit -path $path -commit $sourceVersion
        if ([string]::IsNullOrWhiteSpace($original)) {
            # File referenced in the error logs but NOT found in this repo. Most likely it
            # lives in a resource repo (e.g. 'goldsuite') or is a generated/temp file.
            # We cannot branch/PR another repo from here, so flag it for a human instead.
            # Only flag as external if it looks like a real project-relative path,
            # not a system path, runner temp, gem directory, or external URL.
            $isProjectPath = (
                $path -notmatch '(?i)(usr/local|runner/work/_temp|/gems/|rubygems|node_modules|\.browserstack\.|api-cloud\.|SYSTEM_DEFAULT|SYSTEM_PULLREQUEST)' -and
                $path -notmatch '(?i)^(Node\.js|Podfile|Gemfile)$' -and
                $path.Contains('/')
            )
            if ($isProjectPath -and $path -match '(?i)\.(sh|ps1|rb|yml|yaml|swift|kt|js|ts)$|Fastfile|Podfile|Gemfile') {
                $script:externalFiles.Add($path)
            }
            continue
        }

        # ── BINARY BOM DETECTION ─────────────────────────────────────────────
        # Get-FileFromCommit reads through ADO REST API which strips the UTF-8 BOM
        # (0xEF 0xBB 0xBF) when decoding the HTTP response — $original never has BOM.
        # To detect and auto-fix BOM we must read raw bytes from the agent's checkout.
        # If BOM is present, we synthesise a fix with old_code that explicitly starts
        # with the BOM character (U+FEFF) so the remediator's binary file reader can
        # match and remove it. This ensures old_code ≠ new_code (not a no-op).
        $diskFilePath = Join-Path $env:BUILD_SOURCESDIRECTORY $path
        if (($path -match '\.sh$') -and (Test-Path $diskFilePath)) {
            try {
                $rawBytes = [System.IO.File]::ReadAllBytes($diskFilePath)
                if ($rawBytes.Count -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
                    # File on disk HAS BOM. Synthesise a fix: old_code = BOM+line1, new_code = line1
                    $firstLineClean = ($original -split "`n")[0]
                    # Strip any existing \uFEFF chars that UTF-8 decoding already placed in
                    # the string — we prepend exactly ONE below for old_code.
                    # Without this, old_code gets TWO BOMs (the prepended one + the decoded
                    # one), new_code gets ONE, and PS .Trim() strips both making old==new
                    # after normalization → the fix is incorrectly skipped as no-op.
                    $firstLineClean = $firstLineClean.TrimStart([char]0xFEFF)
                    $allFixes.Add([PSCustomObject]@{
                        file_path   = $path
                        line_number = 1
                        title       = "Remove UTF-8 BOM from first line"
                        old_code    = ([char]0xFEFF) + $firstLineClean
                        new_code    = $firstLineClean
                        confidence  = 1.0
                    })
                    $fileStatus.Add("✅ $path — UTF-8 BOM detected and queued for removal (fix applied by remediator via binary I/O).")
                    continue  # file content is otherwise clean (BOM was the only issue)
                }
            } catch { <# disk read failed gracefully — fall through to normal validation #> }
        }

        # Quick skip: if file already parses clean, it isn't the culprit
        $firstCheck = Get-SyntaxError -filePath $path -content $original
        if ($firstCheck.Ok) {
            # ── UNBOUND VARIABLE DETECTOR ────────────────────────────────────────
            # bash -n validates syntax only — it cannot detect runtime "unbound variable"
            # errors (from set -u or strict bash mode). A typo like ${BUNDLER_VERSIO}
            # is syntactically valid bash but crashes at runtime because the variable
            # doesn't exist.
            #
            # Strategy: if the BUILD LOG contains "X: unbound variable" AND the
            # candidate file contains $X or ${X} → the file IS the culprit even though
            # bash -n says it's clean. Force an AI review with the runtime error context
            # so the AI can identify the typo (e.g. BUNDLER_VERSIO → BUNDLER_VERSION).
            $unboundForced = $false
            $unboundMatches = [regex]::Matches($logStr, '\b([A-Z][A-Z0-9_]{3,})\s*:\s*unbound variable', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            foreach ($uvm in $unboundMatches) {
                $unboundVar = $uvm.Groups[1].Value.Trim()
                # Check if this file uses the unbound variable
                if ($original -match ('\$\{?' + [regex]::Escape($unboundVar) + '\}?')) {
                    Write-Host "⚠️ Unbound variable runtime error: '$unboundVar' used in $path — forcing AI review"
                    # Locate the line in this file
                    $unboundLineNum = 1
                    $fileLines = $original -split "\r?\n"
                    for ($fi = 0; $fi -lt $fileLines.Count; $fi++) {
                        if ($fileLines[$fi] -match ('\$\{?' + [regex]::Escape($unboundVar) + '\}?')) {
                            $unboundLineNum = $fi + 1; break
                        }
                    }
                    # Inject a synthetic error so the AI review path fires
                    $firstCheck = [PSCustomObject]@{
                        Ok      = $false
                        Message = "$($unboundVar): unbound variable — this is a runtime error (bash -n does not catch it). The variable is likely a TYPO of a nearby correctly-named variable. Look at surrounding lines for the intended name."
                        Line    = $unboundLineNum
                    }
                    $unboundForced = $true
                    break
                }
            }

            if (-not $unboundForced) {
                # ── SEMANTIC FALLBACK REVIEW ─────────────────────────────────
                # BUGFIX: Ok=$true here can mean "a real compiler/linter confirmed
                # this file is clean" OR "no real tool was available, so only a
                # brace/paren/bracket balance check ran" (Fallback=$true — see the
                # Get-SyntaxError / Test-StructuralSyntax / Test-VueSyntax call
                # sites). Previously both cases were treated identically and the
                # file was marked clean and skipped — meaning files reviewed only
                # by the structural fallback NEVER got a semantic AI pass, even
                # though that fallback exists precisely because it has narrower
                # coverage than a real compiler. Run one semantic review pass for
                # these files before marking them clean.
                if ($firstCheck.Fallback) {
                    try {
                        $semanticResult = Invoke-SemanticFallbackReview -path $path -content $original -prior $null
                        if ($semanticResult -ne $original) {
                            # Re-verify the semantic-review edits didn't introduce a
                            # structural problem before accepting them as the new
                            # baseline for this file.
                            $semanticVerify = Get-SyntaxError -filePath $path -content $semanticResult
                            if ($semanticVerify.Ok) {
                                $original = $semanticResult
                                $fileStatus.Add("✅ $path — semantic review found and fixed issue(s) not caught by structural-only validation.")
                            } else {
                                Write-Host "  ⚠️ ${path}: semantic-review edit introduced a structural error — discarding and keeping original."
                            }
                        }
                    } catch {
                        # Defense in depth: the script has only ONE top-level try/catch
                        # (around the whole run). A failure here must not abort
                        # processing of every other file — keep $original unchanged
                        # and let this file proceed as structurally clean.
                        Write-Host "  ⚠️ ${path}: semantic fallback verification failed ($($_.Exception.Message)) — keeping original content."
                    }
                }
                [void]$script:cleanFiles.Add($path)
                # Even if clean, follow template references in YAML so we don't miss
                # broken templates that are called by this file.
                if ($path -match '\.ya?ml$') {
                    foreach ($tRef in ([regex]::Matches($original, '(?m)^\s*-?\s*template:\s*(.+)$'))) {
                        $tPath = $tRef.Groups[1].Value.Trim().Trim('"''')
                        if (-not [string]::IsNullOrWhiteSpace($tPath) -and $tPath -match '\.ya?ml$') {
                            if ($candidatePaths.Add($tPath)) {
                                [void]$pathsToProcess.Add($tPath)
                                Write-Host "  🔗 Following template reference: $tPath"
                            }
                        }
                    }
                }
                continue
            }
        }

        Write-Host "🔧 Repairing $path (parser reports errors)..."
        # Per-file prior version: find the most recent commit BEFORE the current one that
        # actually touched THIS file. A branch-wide prior commit may not have changed it,
        # so this yields a more relevant "before it broke" reference for the AI.
        $prior = $null
        $fileCommitsUrl = "$collectionUri$teamProject/_apis/git/repositories/$repoId/commits?searchCriteria.itemPath=$([uri]::EscapeDataString('/' + $path))&searchCriteria.`$top=5&api-version=7.1"
        $fileCommits = Invoke-ADORestMethod -Uri $fileCommitsUrl
        if ($null -ne $fileCommits -and $null -ne $fileCommits.value -and @($fileCommits.value).Count -gt 1) {
            $prior = Get-FileFromCommit -path $path -commit $fileCommits.value[1].commitId
        }
        if ([string]::IsNullOrWhiteSpace($prior) -and -not [string]::IsNullOrWhiteSpace($priorCommitId)) {
            $prior = Get-FileFromCommit -path $path -commit $priorCommitId
        }

        $working = $original
        $iter    = 0
        $lastSig = ""
        $stuck   = 0
        $failedApplyStreak = 0   # how many consecutive iterations produced zero applied fixes
        $importErrorInjected = $false   # BUGFIX: was gated on "$iter -eq 0" below, which meant
                                         # a file with BOTH a real syntax error AND a missing
                                         # import would silently never get the import fix --
                                         # by the time syntax became clean (chk.Ok=True), $iter
                                         # was no longer 0 (it had advanced across the syntax
                                         # fix iterations), so the injection branch was never
                                         # reached at all. Tracked separately so it fires
                                         # whichever iteration the file FIRST becomes syntax-
                                         # clean, not only if it was clean from iteration zero.
        while ($iter -lt $MAX_ITERS_PER_FILE) {
            $chk = Get-SyntaxError -filePath $path -content $working
            if ($chk.Ok) {
                # ── IMPORT ERROR INJECTION ──────────────────────────────────────
                # Syntax is clean BUT the build logs reported a missing import for
                # this file. Import errors pass syntax validation (python3 -m
                # py_compile checks syntax only — not whether the module exists).
                # Inject a synthetic error so the AI is called to add the missing
                # import statement. The fix is validated by re-running the parser
                # (which passes as long as the import syntax is correct); the next
                # build verifies the package is actually installed.
                if ($importErrorMap.ContainsKey($path) -and -not $importErrorInjected) {
                    $importErrorInjected = $true
                    $ie = $importErrorMap[$path]
                    Write-Host "  ℹ️ Syntax clean but import error detected: $($ie.Symbol) ($($ie.Lang))"
                    $chk = @{ Ok = $false; Line = 1; Message = $ie.Message }

                    # ── DEPENDENCY MANIFEST FIX ──────────────────────────────
                    # Alongside adding the import statement, automatically fix the
                    # dependency manifest (requirements.txt, package.json, Gemfile
                    # etc.) so the package is ALSO installed on the next build.
                    # Only runs once per file (tracked via $importErrorInjected, not
                    # $iter — see the bugfix note where that flag is declared above
                    # the while loop) — once the import is in place the syntax check
                    # passes and we break out on the following iteration.
                    $repoRoot = $env:BUILD_SOURCESDIRECTORY
                    $depFile  = Find-DependencyFile -sourcePath $path -lang $ie.Lang -repoRoot $repoRoot
                    if ($null -ne $depFile) {
                        Write-Host "  📦 Found dependency manifest: $depFile"
                        $depContent = Get-FileFromCommit -path $depFile -commit $sourceVersion
                        if (-not [string]::IsNullOrWhiteSpace($depContent)) {
                            $depFix = New-PackageDependencyFix `
                                -depFilePath    $depFile `
                                -depFileContent $depContent `
                                -symbol         $ie.Symbol `
                                -lang           $ie.Lang `
                                -repoRoot       $repoRoot
                            if ($null -ne $depFix) {
                                $allFixes.Add($depFix)
                                $iter++
                                Write-Host "  ✅ Dependency fix queued: add '$($ie.Symbol)' to $depFile"
                            }
                        }
                    } else {
                        Write-Host "  ⚠️ No dependency manifest found for $($ie.Lang) — add package manually after PR."
                    }
                } else {
                    # ── SEMANTIC FALLBACK REVIEW ─────────────────────────────
                    # Same bug as the outer fast-path skip above: $chk.Ok=$true
                    # can mean "structural-only fallback passed" (Fallback=$true),
                    # not "a real compiler/linter confirmed this file is clean".
                    # Run one semantic AI pass before declaring the file done,
                    # so files that only got fixed up to structural-cleanliness
                    # still get reviewed for real bugs.
                    #
                    # NOTE: a confidence-based skip (bypassing this pass when the
                    # resolving fix's own confidence was >= 0.9) was tried and
                    # then explicitly REVERTED per instruction -- every file that
                    # passes only via the structural fallback gets this semantic
                    # review unconditionally, regardless of cost.
                    if ($chk.Fallback) {
                        try {
                            $semanticResult = Invoke-SemanticFallbackReview -path $path -content $working -prior $prior
                            if ($semanticResult -ne $working) {
                                $semanticVerify = Get-SyntaxError -filePath $path -content $semanticResult
                                if ($semanticVerify.Ok) {
                                    $working = $semanticResult
                                } else {
                                    Write-Host "  ⚠️ ${path}: semantic-review edit introduced a structural error — discarding and keeping prior working version."
                                }
                            }
                        } catch {
                            # Defense in depth: keep $working unchanged and let the file
                            # finish as structurally clean rather than abort the run.
                            Write-Host "  ⚠️ ${path}: semantic fallback verification failed ($($_.Exception.Message)) — keeping prior working version."
                        }
                    }
                    Write-Host "✅ $path is now clean after $iter fix(es)."; break
                }
            }

            $sig = "$($chk.Line)|$($chk.Message)"
            if ($sig -eq $lastSig) { $stuck++ } else { $stuck = 0 }
            $lastSig = $sig
            if ($stuck -ge 2) { Write-Host "⚠️ ${path}: parser not advancing (same error twice). Stopping."; break }

            if ($script:aiCallCount -ge $MAX_TOTAL_AI_CALLS) {
                Write-Host "⚠️ Global AI call ceiling ($MAX_TOTAL_AI_CALLS) reached. Stopping to control cost."
                break
            }

            # ── PHASE 1: BATCH DETERMINISTIC PASS (no AI, no tokens) ──────────
            # Repair-AllUnclosedQuotes + Repair-AllUnclosedSubstitutions scan the
            # entire bash block in one chained pass.  Two separate error classes:
            #  • Unclosed " quote  → Repair-AllUnclosedQuotes
            #  • Unclosed $( paren → Repair-AllUnclosedSubstitutions (NEW)
            # Repair-AllUnclosedDelimiters handles ", $(, and ${ in ONE pass.
            # Also triggers on "bad substitution" (pure ${ error with no quote issue).
            $isQuoteSymptom = ($chk.Message -match '(?i)(EOF|unexpected end|looking for matching|syntax error near unexpected|near unexpected token|TerminatorExpected|MissingEndCurlyBrace|bad substitution|substitution error)')
            $detFixed = $false
            if ($isQuoteSymptom) {
                $blocksForDet = if ($path -match '\.ya?ml$') {
                    Get-InlineScriptBlocks -yamlContent $working | Where-Object { $_.Kind -eq 'bash' }
                } else { $null }

                if ($null -ne $blocksForDet) {
                    foreach ($b in $blocksForDet) {
                        # ── COMBINED SCANNER — one fix per line, all delimiter types ──
                        # Repair-AllUnclosedDelimiters fixes ", $(, and ${ in one pass.
                        # Each line gets exactly ONE fix entry — no duplicates possible.
                        # The ${ fix uses regex INSERT to place } in the correct position
                        # (right after the variable name, before any trailing chars).
                        $delimResult = Repair-AllUnclosedDelimiters -content $b.Body

                        if ($delimResult.Fixes.Count -gt 0) {
                            $tempWorking = $working
                            $stagedFixes = [System.Collections.Generic.List[PSCustomObject]]::new()
                            foreach ($df in @($delimResult.Fixes)) {
                                $targetYamlLine = $b.YamlStartLine + $df.BlockLine - 1
                                $applied = Apply-FixByLine -content $tempWorking -lineNumber $targetYamlLine -newCode ($df.FixedLine.Trim()) -filePath $path
                                if ($applied.Applied) {
                                    $tempWorking = $applied.Content
                                    $stagedFixes.Add([PSCustomObject]@{
                                        file_path   = $path
                                        line_number = $targetYamlLine
                                        title       = $df.Title
                                        confidence  = 1.0
                                        old_code    = $applied.OldLine
                                        new_code    = $applied.NewLine
                                    })
                                    Write-Host "  ✅ Det-fix staged at YAML line $targetYamlLine [$($df.Title)] (0 tokens)"
                                }
                            }
                            $verify = Get-SyntaxError -filePath $path -content $tempWorking
                            if ($verify.Ok -or "$($verify.Line)|$($verify.Message)" -ne $sig) {
                                $working = $tempWorking
                                foreach ($sf in $stagedFixes) { $allFixes.Add($sf); $iter++ }
                                $detFixed = $true; break
                            }
                        }
                    }
                } elseif ($path -match '\.sh$') {
                    $delimResult = Repair-AllUnclosedDelimiters -content $working

                    if ($delimResult.Fixes.Count -gt 0) {
                        $tempWorking = $working
                        $stagedFixes = [System.Collections.Generic.List[PSCustomObject]]::new()
                        foreach ($df in @($delimResult.Fixes)) {
                            $applied = Apply-FixByLine -content $tempWorking -lineNumber $df.BlockLine -newCode ($df.FixedLine.Trim()) -filePath $path
                            if ($applied.Applied) {
                                $tempWorking = $applied.Content
                                $stagedFixes.Add([PSCustomObject]@{
                                    file_path   = $path
                                    line_number = $df.BlockLine
                                    title       = $df.Title
                                    confidence  = 1.0
                                    old_code    = $applied.OldLine
                                    new_code    = $applied.NewLine
                                })
                                Write-Host "  ✅ Det-fix staged at line $($df.BlockLine) [$($df.Title)] (0 tokens)"
                            }
                        }
                        $verify = Get-SyntaxError -filePath $path -content $tempWorking
                        if ($verify.Ok -or "$($verify.Line)|$($verify.Message)" -ne $sig) {
                            $working = $tempWorking
                            foreach ($sf in $stagedFixes) { $allFixes.Add($sf); $iter++ }
                            $detFixed = $true
                        }
                    }
                }
            }
            if ($detFixed) {
                $script:aiCache.Remove("$path|$($chk.Message)|$($chk.Line)") | Out-Null
                $stuck = 0; $lastSig = ""
                # BUGFIX: $failedApplyStreak previously only reset inside Phase 2's
                # own success branch (further below) -- so if Phase 2 failed to
                # apply a fix once or twice, THEN a deterministic fix here made
                # genuine forward progress on a DIFFERENT error, the old failure
                # count would carry forward unreset. A single subsequent Phase 2
                # failure could then hit the "3 consecutive" ceiling and abandon
                # the file early, even though real progress had just been made.
                # Any genuine change to $working is forward progress and should
                # clear this counter, regardless of which phase produced it.
                $failedApplyStreak = 0
                continue
            }

            # ── PHASE 1.5: CRLF → LF CONVERSION (additive, zero AI tokens) ────
            # Windows-authored files committed with CRLF (\r\n) line endings cause
            # bash errors like '\r: command not found' on Linux/macOS CI agents.
            # Detect if the file content has CRLF AND the parser error mentions it,
            # OR if converting to LF resolves (or changes) the parser error.
            # This runs AFTER the quote/subst det-scan so it doesn't interfere.
            if (-not $detFixed -and $working -match "\r\n" -and
                ($chk.Message -match '(?i)(\r|\\r|carriage|crlf|windows.*line|line ending)' -or
                 $path -match '\.(?:sh|bash|ps1|rb|py|js|ts|jsx|tsx|go|kt|kts|swift|java)$')) {
                $lfContent  = $working -replace "\r\n", "`n"
                $verifyCrlf = Get-SyntaxError -filePath $path -content $lfContent
                if ($verifyCrlf.Ok -or "$($verifyCrlf.Line)|$($verifyCrlf.Message)" -ne $sig) {
                    $allFixes.Add([PSCustomObject]@{
                        file_path    = $path
                        line_number  = 1
                        title        = "Fix Windows CRLF line endings — convert to Unix LF (det-scan)"
                        old_code     = "(Windows CRLF line endings)"
                        new_code     = "(Unix LF line endings)"
                        confidence   = 1.0
                        _fullContent = $lfContent
                    })
                    $working  = $lfContent
                    $detFixed = $true
                    $script:aiCache.Remove("$path|$($chk.Message)|$($chk.Line)") | Out-Null
                    $stuck = 0; $lastSig = ""
                    # Same fix as the Phase 1 quote/substitution det-scan above:
                    # genuine progress here should clear any failure count left
                    # over from an earlier, now-irrelevant Phase 2 AI-apply
                    # failure on a different error in this same file.
                    $failedApplyStreak = 0
                    Write-Host "  ✅ CRLF → LF conversion staged at $path (0 tokens)"
                    continue
                }
            }

            # ── PHASE 2: AI DEVELOPER-MODE BATCH CALL ──────────────────────────
            # Send the FULL file (not a window) and ask the AI to find ALL issues.
            # AI returns an array of fixes; each is validated by the parser.
            # A developer reads the whole file — so does the AI now.
            $numberedFull = Add-LineNumbers -content (Protect-Secrets $working)
            $aiFixes = Get-AIFixes -filePath $path -numberedContent $numberedFull -parserError $chk.Message -errorLine $chk.Line -priorVersion (Protect-Secrets $prior)

            if ($null -eq $aiFixes -or $aiFixes.Count -eq 0) {
                Write-Host "⚠️ ${path}: AI returned no fixes for: $($chk.Message). Stopping."; break
            }

            # Apply each AI fix in line-number order (ascending prevents offset drift)
            $sortedFixes = $aiFixes | Where-Object { $null -ne $_.line_number -and $null -ne $_.new_code } |
                           Sort-Object { [int]$_.line_number }
            $anyApplied = $false
            foreach ($fix in $sortedFixes) {
                [int]$targetLine = 0
                if (-not [int]::TryParse([string]$fix.line_number, [ref]$targetLine) -or $targetLine -lt 1) { continue }

                # Guard: reject fixes that insert bare YAML structural keywords.
                # The AI sometimes "fixes" an empty first line to steps: or jobs:,
                # duplicating a key that already exists elsewhere in the file.
                $newCodeTrimmed = ([string]$fix.new_code).Trim()
                $isYamlStructure = ($newCodeTrimmed -match '(?i)^(?:steps|jobs|stages|trigger|resources|variables|parameters|pool|extends|pr|schedules)\s*:\s*$')
                if ($isYamlStructure) {
                    Write-Host "    ⚠️ Rejected hallucinated structural fix at line $targetLine : '$newCodeTrimmed' — this is a YAML key, not a script error."
                    continue
                }

                # Guard: reject fixes to lines that are YAML task metadata —
                # displayName, task, inputs, condition, env, etc. These are
                # never syntax errors in a bash/PS block and should not be touched.
                if ($null -ne $working) {
                    $lineArr = $working -split "\r?\n"
                    if ($targetLine -le $lineArr.Count) {
                        $origLine = $lineArr[$targetLine - 1]
                        $isYamlMeta = ($origLine.Trim() -match '(?i)^(?:task|displayName|inputs|condition|env|name|dependsOn|timeoutInMinutes|continueOnError|enabled|pool|uses)\s*:')
                        if ($isYamlMeta) {
                            Write-Host "    ⚠️ Rejected fix to YAML metadata line $targetLine : '$($origLine.Trim())'"
                            continue
                        }
                    }
                }

                $applied = Apply-FixByLine -content $working -lineNumber $targetLine -newCode $fix.new_code -filePath $path
                if (-not $applied.Applied) { continue }
                # Guard: skip no-op fixes where the AI returned the same content already on
                # the line. Apply-FixByLine always returns Applied=$true for in-range lines,
                # even when OldLine == NewLine. Without this check, these dummy fixes flow
                # through to the Teams card and the remediator where they appear as 9/12
                # "no-op skipped" entries — wasting card space and confusing the developer.
                #
                # BUGFIX (real incident, confirmed via live test run): the original check
                # collapsed ALL whitespace runs (including LEADING whitespace) to a single
                # space before comparing -- which made a genuinely correct Makefile tab-fix
                # (replacing leading SPACES with a leading TAB, the entire point of GNU
                # make's "missing separator" fix) look identical to the broken original
                # after normalization, since both collapse to the same string once leading
                # whitespace is flattened. The fix was rejected as a no-op three times in a
                # row, exhausting the retry budget, and common.mk was never actually
                # repaired. Leading whitespace is now compared EXACTLY (so a tab-vs-spaces
                # change is correctly recognized as real), while internal whitespace runs
                # within the rest of the line are still collapsed -- preserving the
                # original, valid use case of catching truly cosmetic AI non-changes.
                $oldLeadMatch = [regex]::Match($applied.OldLine, '^([ \t]*)(.*)$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
                $newLeadMatch = [regex]::Match($applied.NewLine, '^([ \t]*)(.*)$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
                $oldLeading = $oldLeadMatch.Groups[1].Value; $oldRest = $oldLeadMatch.Groups[2].Value
                $newLeading = $newLeadMatch.Groups[1].Value; $newRest = $newLeadMatch.Groups[2].Value
                $oldRestNorm = ($oldRest -replace '\s+',' ').Trim()
                $newRestNorm = ($newRest -replace '\s+',' ').Trim()
                if (($oldLeading -eq $newLeading) -and ($oldRestNorm -eq $newRestNorm)) {
                    Write-Host "    ⚠️ Skipping no-op fix at line $targetLine (old_code == new_code after normalization)"
                    continue
                }
                $working = $applied.Content
                $anyApplied = $true
                $thisFixConfidence = if($null -ne $fix.confidence){$fix.confidence}else{0.9}
                $allFixes.Add([PSCustomObject]@{
                    file_path=$path; line_number=$targetLine
                    title=if([string]::IsNullOrWhiteSpace($fix.title)){"AI fix in $([IO.Path]::GetFileName($path))"}else{$fix.title}
                    old_code=$applied.OldLine; new_code=$applied.NewLine
                    confidence=$thisFixConfidence
                })
                Write-Host "  ➡️ AI-fix at line $targetLine : $($fix.title)"
                $iter++
            }
            if (-not $anyApplied) {
                # ── STALE CACHE RECOVERY ──────────────────────────────────────────
                # ALL Apply strategies failed for every fix in the batch. This almost
                # always means the fix came from in-run cache or cross-run memory and
                # its line numbers / old_code no longer match the current file state.
                #
                # Strategy:
                #   1. Evict the stale in-run cache entry so the NEXT iteration calls
                #      AI fresh (not the same wrong cached fix again).
                #   2. Penalise the cross-run memory entry (evict at 2 failures).
                #   3. Reset the stuck guard — "same error" on next iteration is not
                #      a stuck situation, just the result of zero change this iteration.
                #   4. Break only after 3 consecutive zero-apply iterations (the fresh
                #      AI call has had its chance) to prevent infinite loops.
                $failedApplyStreak++
                if ($failedApplyStreak -ge 3) {
                    Write-Host "⚠️ ${path}: no fix applied in 3 consecutive iterations for: $($chk.Message). Stopping."
                    break
                }
                $staleCacheKey = "$path|$($chk.Message)|$($chk.Line)"
                if ($script:aiCache.ContainsKey($staleCacheKey)) {
                    $script:aiCache.Remove($staleCacheKey) | Out-Null
                    Write-Host "    ↩ Stale cache evicted for [$([IO.Path]::GetFileName($path))] — next iteration calls AI fresh."
                }
                # Penalise cross-run memory if this was a memory-served fix.
                if ($null -ne $script:memServed -and $script:memServed.ContainsKey($path)) {
                    $badSig = $script:memServed[$path]
                    if ($null -ne $script:fixMemory -and $script:fixMemory.ContainsKey($badSig)) {
                        $script:fixMemory[$badSig].fails = [int]$script:fixMemory[$badSig].fails + 1
                        Write-Host "    ↩ Memory fix unapplicable (fails=$($script:fixMemory[$badSig].fails))$(if ([int]$script:fixMemory[$badSig].fails -ge 2) {' — evicting.'} else {'.'})"
                        if ([int]$script:fixMemory[$badSig].fails -ge 2) {
                            $script:fixMemory.Remove($badSig) | Out-Null
                        }
                    }
                    $script:memServed.Remove($path) | Out-Null
                }
                # Reset stuck guard: this iteration made ZERO change to $working, so
                # "same error next iteration" is expected — not a true stuck situation.
                $lastSig = ""; $stuck = 0
                Write-Host "    ↩ No fix applied (streak=$failedApplyStreak/3) — retrying with fresh AI call."
            } else {
                $failedApplyStreak = 0   # a fix was applied — reset the no-progress streak
            }
            # After applying all batch fixes, recheck the parser to update $sig for stuck-guard
            $postBatch = Get-SyntaxError -filePath $path -content $working
            $sig = "$($postBatch.Line)|$($postBatch.Message)"
        }

        $finalChk = Get-SyntaxError -filePath $path -content $working
        if ($finalChk.Ok) { $fileStatus.Add("✅ $path — all syntax errors fixed and parser-verified.") }
        else {
            # Actionable escalation: surface WHAT is still broken (first error line + message),
            # not just "manual review needed". Truncated to keep the Teams payload small.
            $remErr = (("$($finalChk.Message)" -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($remErr.Length -gt 200) { $remErr = $remErr.Substring(0, 200) + '…' }
            $atLine = if ($finalChk.Line -gt 0) { " at line $($finalChk.Line)" } else { "" }
            $fileStatus.Add("⚠️ $path — $iter fix(es) applied but parser still reports an error$atLine`: $remErr — needs manual review.")
        }

        # ── CROSS-RUN FIX MEMORY: reconcile this file's outcome ───────────
        # Promote a staged AI batch to persisted memory ONLY if the file is now
        # parser-clean. Adjust the served signature's fail/hit counters so a
        # remembered fix that stops working is evicted (fails >= 2 => not served).
        # Fully guarded: any failure leaves memory unchanged and triage continues.
        try {
            $memNow    = [datetime]::UtcNow.ToString('yyyy-MM-dd')
            $servedSig = if ($null -ne $script:memServed -and $script:memServed.ContainsKey($path)) { $script:memServed[$path] } else { $null }
            if ($finalChk.Ok) {
                # Memory-served fix validated — increment hits, refresh lastUsed, clear fails
                if ($null -ne $servedSig -and $script:fixMemory.ContainsKey($servedSig)) {
                    $script:fixMemory[$servedSig].fails    = 0
                    $script:fixMemory[$servedSig].hits     = [int]$script:fixMemory[$servedSig].hits + 1
                    $script:fixMemory[$servedSig].lastUsed = $memNow   # IMP-3: refresh so TTL stays alive
                }
                # New AI fix validated — promote to permanent memory with timestamps
                if ($null -ne $script:memLearn -and $script:memLearn.ContainsKey($path)) {
                    $entry = $script:memLearn[$path]
                    if (-not [string]::IsNullOrWhiteSpace($entry.Sig) -and @($entry.Fixes).Count -gt 0) {
                        if ($script:fixMemory.ContainsKey($entry.Sig)) {
                            # Update existing — refresh content and hit count; preserve created
                            $script:fixMemory[$entry.Sig].fixes    = @($entry.Fixes)
                            $script:fixMemory[$entry.Sig].fails    = 0
                            $script:fixMemory[$entry.Sig].hits     = [int]$script:fixMemory[$entry.Sig].hits + 1
                            $script:fixMemory[$entry.Sig].lastUsed = $memNow   # IMP-3: refresh
                        } else {
                            # Brand-new entry — set both timestamps (IMP-2)
                            $script:fixMemory[$entry.Sig] = @{
                                fixes    = @($entry.Fixes)
                                fails    = 0
                                hits     = 1
                                created  = $memNow
                                lastUsed = $memNow
                            }
                            $script:memStats.newEntries++
                        }
                    }
                }
            } else {
                if ($null -ne $servedSig -and $script:fixMemory.ContainsKey($servedSig)) {
                    $script:fixMemory[$servedSig].fails = [int]$script:fixMemory[$servedSig].fails + 1
                }
            }
            if ($null -ne $script:memServed) { $script:memServed.Remove($path) | Out-Null }
            if ($null -ne $script:memLearn)  { $script:memLearn.Remove($path)  | Out-Null }
        } catch { Write-Host "    ⓘ Memory reconcile skipped: $($_.Exception.Message)" }
    }

    Write-Host "[INFO] Total parser-verified fixes across all files: $($allFixes.Count)"

    # ──────────────────────────────────────────────────────────────────
    #  PACKAGE + DISPATCH
    # ──────────────────────────────────────────────────────────────────
    # Build a type-accurate summary — 'syntax errors' is wrong for plugin/bundler/credential/pod/npm fixes
    $syntaxFixes  = @($allFixes | Where-Object { $_.title -notmatch '(?i)(MANUAL ACTION|Fastlane plugin|Add missing gem|bundler error|CocoaPod|npm module|package\.json|Python module|requirements|Ruby version|bundler version|Makefile.*TAB|CRLF|Gradle dependency|Swift Package|Carthage|Xcode scheme)' })
    $pluginFixes  = @($allFixes | Where-Object { $_.title -match '(?i)Fastlane plugin' })
    $bundlerFixes2= @($allFixes | Where-Object { $_.title -match '(?i)(Add missing gem|bundler error)' })
    $podFixes2    = @($allFixes | Where-Object { $_.title -match '(?i)CocoaPod' })
    $npmFixes2    = @($allFixes | Where-Object { $_.title -match '(?i)(npm module|package\.json)' })
    $pyFixes2     = @($allFixes | Where-Object { $_.title -match '(?i)(Python module|requirements)' })
    $gradleFixes2 = @($allFixes | Where-Object { $_.title -match '(?i)Gradle dependency' })
    $spmFixes2    = @($allFixes | Where-Object { $_.title -match '(?i)(Swift Package|SPM)' })
    $cartFixes2   = @($allFixes | Where-Object { $_.title -match '(?i)Carthage' })
    $schemeFixes2 = @($allFixes | Where-Object { $_.title -match '(?i)Xcode scheme' })
    $detFixes2    = @($allFixes | Where-Object { $_.title -match '(?i)(Ruby version|bundler version|Makefile.*TAB|CRLF|unclosed.*det-scan)' })
    $credFixes    = @($allFixes | Where-Object { $_.title -match '(?i)MANUAL ACTION' })

    $summary = if ($allFixes.Count -gt 0) {
        $parts = @()
        if ($syntaxFixes.Count  -gt 0) { $parts += "$($syntaxFixes.Count) syntax fix(es)" }
        if ($detFixes2.Count    -gt 0) { $parts += "$($detFixes2.Count) deterministic fix(es) (CRLF/Ruby/Makefile)" }
        if ($pluginFixes.Count  -gt 0) { $parts += "$($pluginFixes.Count) Fastlane plugin gem addition(s)" }
        if ($bundlerFixes2.Count -gt 0) { $parts += "$($bundlerFixes2.Count) Gemfile dependency addition(s)" }
        if ($podFixes2.Count    -gt 0) { $parts += "$($podFixes2.Count) CocoaPod addition(s) to Podfile" }
        if ($npmFixes2.Count    -gt 0) { $parts += "$($npmFixes2.Count) npm module addition(s) to package.json" }
        if ($pyFixes2.Count     -gt 0) { $parts += "$($pyFixes2.Count) Python module addition(s) to requirements.txt" }
        if ($gradleFixes2.Count -gt 0) { $parts += "$($gradleFixes2.Count) Gradle dependency addition(s) to build.gradle" }
        if ($spmFixes2.Count    -gt 0) { $parts += "$($spmFixes2.Count) Swift Package Manager fix(es) to Package.swift" }
        if ($cartFixes2.Count   -gt 0) { $parts += "$($cartFixes2.Count) Carthage fix(es) to Fastfile/Cartfile" }
        if ($schemeFixes2.Count -gt 0) { $parts += "$($schemeFixes2.Count) Xcode scheme fix(es)" }
        if ($credFixes.Count    -gt 0) { $parts += "$($credFixes.Count) credential/config item(s) needing manual setup" }
        "🔍 Found $($parts -join ', '). Scanned $($processedPaths.Count) file(s): $($script:cleanFiles.Count) already clean.`n`n" + ($fileStatus -join "`n")
    } else {
        "🔍 Scanned $($processedPaths.Count) file(s) — all clean. Build failure is likely a runtime/logic issue, 3rd-party outage, or permission problem, not a syntax bug. Manual review recommended."
    }
    if ($script:externalFiles.Count -gt 0) {
        $summary += "`n`n⚠️ These files were referenced by the error but are NOT in this repo (likely a resource repo such as 'goldsuite' or a generated file). They cannot be auto-fixed here and need manual review:`n - " + ($script:externalFiles -join "`n - ")
    }

    # ── OVERALL SEVERITY ROLLUP ────────────────────────────────────────
    # Take the WORST severity seen across every file the AI actually
    # reviewed this run (not a per-fix value -- one severity per FILE,
    # since that's what Get-AIFixes's prompt asks for and stashes).
    # Purely additive: if no file ever populated $script:fileSeverity
    # (e.g. every fix this run came from a deterministic, zero-AI fixer),
    # this whole block is silently skipped and the summary is unchanged
    # from before this feature existed.
    if ($null -ne $script:fileSeverity -and $script:fileSeverity.Count -gt 0) {
        $severityRank = @{ critical = 4; high = 3; medium = 2; low = 1 }
        $worstSeverity = $script:fileSeverity.Values |
                         Sort-Object { $severityRank[$_] } -Descending |
                         Select-Object -First 1
        $severityEmoji = @{ critical = '🔴'; high = '🟠'; medium = '🟡'; low = '🟢' }[$worstSeverity]
        $summary = "$severityEmoji **Severity: $($worstSeverity.ToUpper())**`n`n" + $summary
    }

    # ── PREVENTION TIPS ──────────────────────────────────────────────────
    # Deduplicated (the same class of error in multiple files would
    # otherwise repeat the identical tip several times) and capped at 5
    # so this can never meaningfully grow the payload toward the Teams
    # 28KB limit even on a large multi-file run.
    if ($null -ne $script:filePreventionTip -and $script:filePreventionTip.Count -gt 0) {
        $uniqueTips = @($script:filePreventionTip.Values | Select-Object -Unique | Select-Object -First 5)
        if ($uniqueTips.Count -gt 0) {
            $summary += "`n`n🛡️ **Prevention tips:**`n - " + ($uniqueTips -join "`n - ")
        }
    }

    $webhookFixes  = @()
    $artifactFixes = @()
    $idx = 1

    # Sort: real code fixes first (have an ACTUAL code diff), generic/manual
    # entries last. The Teams card diff preview shows the FIRST fix — make
    # sure it's a real one.
    # BUGFIX: the previous logic classified fixes by matching the word
    # "MANUAL ACTION" in the title string, plus a separate null/empty check
    # on old_code. That meant:
    #   1. A fix with old_code SET but IDENTICAL to new_code (a true no-op —
    #      e.g. a fix the AI "applied" that changed nothing) was still
    #      counted as a real code fix and shown in Teams with what looks
    #      like an empty/no-change diff.
    #   2. Classification depended on a title string substring instead of
    #      the actual data — fragile if a title is ever phrased differently.
    # Fixed by evaluating the data directly: a real code fix is one where
    # old_code is not null AND old_code is genuinely different from
    # new_code. Everything else (no old_code, or old_code == new_code) is
    # the generic/manual bucket, regardless of its title text.
    # Use + to concatenate into a FLAT array (nesting @(a,b)|ForEach creates array-of-arrays).
    $codeFixes   = @($allFixes | Where-Object { $null -ne $_.old_code -and "$($_.old_code)" -ne "$($_.new_code)" })
    $manualFixes = @($allFixes | Where-Object { $null -eq  $_.old_code -or  "$($_.old_code)" -eq "$($_.new_code)" })
    $sortedFixes = if ($codeFixes.Count -gt 0 -or $manualFixes.Count -gt 0) { $codeFixes + $manualFixes } else { @() }

    foreach ($f in $sortedFixes) {
        # Truncate old_code/new_code to 300 chars — Teams card payload has a 28 KB limit.
        # Full content is in the artifact for the remediator; Teams only shows the diff preview.
        # IMPORTANT: preserve $null as $null — do NOT convert to "" (Logic App coalesce
        # requires null, not empty string, to trigger the fallback message).
        $oldSnip = if ($null -eq $f.old_code -or "$($f.old_code)" -eq '') {
            $null
        } elseif ("$($f.old_code)".Length -gt 300) {
            "$($f.old_code)".Substring(0, 300) + '…'
        } else {
            "$($f.old_code)"
        }
        $newSnip = if ($null -eq $f.new_code -or "$($f.new_code)" -eq '') {
            $null
        } elseif ("$($f.new_code)".Length -gt 300) {
            "$($f.new_code)".Substring(0, 300) + '…'
        } else {
            "$($f.new_code)"
        }
        $webhookFixes  += [PSCustomObject]@{
            fix_id    = $idx
            title     = $f.title
            file_path = $f.file_path
            old_code  = $oldSnip
            new_code  = $newSnip
        }
        $artifactFixes += [PSCustomObject]@{
            fix_id      = $idx
            title       = $f.title
            file_path   = $f.file_path
            line_number = $f.line_number
            old_code    = $f.old_code
            new_code    = $f.new_code
            confidence  = $f.confidence
            _fullContent = $f._fullContent
        }
        $idx++
    }
    if ($webhookFixes.Count -gt 25) {
        $extra = $webhookFixes.Count - 25
        $webhookFixes = $webhookFixes[0..24]
        $webhookFixes += [PSCustomObject]@{ fix_id = 998; title = "⚠️ $extra more fix(es) in artifact"; file_path = "N/A" }
    }

    $payloadOut = @{ markdown_summary = $summary; independent_fixes = $artifactFixes }
    [System.IO.File]::WriteAllText((Join-Path $artifactDir "ai_fixes.json"), ($payloadOut | ConvertTo-Json -Depth 100 -Compress))
    Write-Host "##vso[task.setvariable variable=AiPayloadPath]$artifactDir"

    $fallbackEmail = if (-not [string]::IsNullOrWhiteSpace($env:DEFAULT_ALERT_EMAIL)) { $env:DEFAULT_ALERT_EMAIL } else { "DevOps_Team_Fallback" }

    # Fetch the commit AUTHOR's email via the ADO Commits API.
    # This is the person who wrote the code, not who triggered the build.
    # BUILD_REQUESTEDFOREMAIL (trigger-er) is intentionally NOT used here.
    $finalEmail = $fallbackEmail
    try {
        $commitUrl = "$collectionUri$teamProject/_apis/git/repositories/$repoId/commits/$([uri]::EscapeDataString($sourceVersion))?api-version=7.1"
        $commitDetail = Invoke-ADORestMethod -Uri $commitUrl
        $authorEmail  = $commitDetail.author.email
        $authorName   = $commitDetail.author.name

        # Detect AI-triggered commits: the remediator signs as ai-bot@subway.com /
        # AI-Remediation-Agent. Also catch generic bot/service patterns.
        $isAiCommit = (
            [string]::IsNullOrWhiteSpace($authorEmail) -or
            $authorEmail  -match '(?i)(ai-bot|no-reply|noreply|service|bot@|\[bot\])' -or
            $authorName   -match '(?i)(AI-Remediation-Agent|service account|pipeline bot|build service)'
        )

        if ($isAiCommit) {
            Write-Host "[INFO] Commit author looks like an AI/bot ('${authorName}' <${authorEmail}>). Using DEFAULT_ALERT_EMAIL."
            $finalEmail = $fallbackEmail
        } else {
            Write-Host "[INFO] Commit author: '${authorName}' <${authorEmail}>. Sending Teams message to them."
            $finalEmail = $authorEmail
        }
    } catch {
        Write-Host "[WARN] Could not fetch commit author email: $($_.Exception.Message). Falling back to DEFAULT_ALERT_EMAIL."
        $finalEmail = $fallbackEmail
    }

    # ── Role-based routing: production files → senior approver ────────
    # If ANY fix touches a file path containing 'prod' or 'production',
    # route the Teams card to the senior engineer group instead of just
    # the commit author. Configure SENIOR_APPROVER_EMAIL in ADO Library.
    $seniorEmail = if ($env:SENIOR_APPROVER_EMAIL) { $env:SENIOR_APPROVER_EMAIL -replace '[\r\n\s]+','' } else { "" }
    $isProdFix = ($webhookFixes | Where-Object {
        $fp = if ($_.file_path) { $_.file_path } else { "" }
        # Match prod/production/release/hotfix in the path
        # BUT exclude non_prod / non-prod / nonprod which are clearly DEV files
        $fp -match '(?i)(prod|production|release|hotfix)' -and
        $fp -notmatch '(?i)(non.?prod|nonprod)'
    }).Count -gt 0
    $routeToEmail = if ($isProdFix -and -not [string]::IsNullOrWhiteSpace($seniorEmail)) {
        Write-Host "[INFO] 🔒 Production file detected — routing approval card to senior approver: $seniorEmail"
        $seniorEmail
    } else { $finalEmail }

    # Collect all fix IDs so the remediator can compute rejected = all - selected
    $allFixIds = ($webhookFixes | Where-Object { $null -ne $_.fix_id } | ForEach-Object { "$($_.fix_id)" }) -join ','

    # ── Dynamic org name + remediator definition ID ────────────────────
    # Org name is extracted from the collection URI — never hardcoded.
    # e.g. https://dev.azure.com/subwaytechnology/ → subwaytechnology
    #      https://subway.visualstudio.com/        → subway
    $orgName = if ($collectionUri -match 'dev\.azure\.com/([^/?]+)') { $Matches[1] } `
               elseif ($collectionUri -match 'https?://([^.]+)\.visualstudio\.com') { $Matches[1] } `
               else { ($collectionUri -replace 'https?://', '' -split '[/.]')[0] }

    # REMEDIATOR_DEFINITION_ID: set in ADO Library (variable group) to your remediator
    # pipeline definition ID. If not set, falls back to the value known at build time.
    $remediatorDefId = if ($env:REMEDIATOR_DEFINITION_ID -and $env:REMEDIATOR_DEFINITION_ID -match '^\d+$') {
        $env:REMEDIATOR_DEFINITION_ID
    } else {
        # Last-resort fallback: use the current run's definition ID.
        # This is wrong if triage and remediator are separate pipelines
        # (they always should be), so always set REMEDIATOR_DEFINITION_ID.
        Write-Host "[WARN] REMEDIATOR_DEFINITION_ID not set — set it in ADO Library for correct routing."
        $definitionId
    }
    Write-Host "[INFO] Org: $orgName | Remediator definition: $remediatorDefId"

    $webhookPayload = @{
        developer_email          = $finalEmail
        route_to_email           = $routeToEmail
        senior_email             = $seniorEmail
        is_prod_fix              = $isProdFix
        all_fix_ids              = $allFixIds
        org_name                 = $orgName
        remediator_definition_id = $remediatorDefId
        build_id = $buildId; definition_id = $definitionId
        project_name = $teamProject; failed_branch = $cleanFailedBranch; ai_summary = $summary
        fixes = $webhookFixes; independent_fixes = $webhookFixes
    } | ConvertTo-Json -Depth 100 -Compress

    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($webhookPayload)
    Write-Host "[INFO] Webhook payload: $($payloadBytes.Length) bytes (Teams limit 28672)."
    if ($payloadBytes.Length -gt 28672) {
        Write-Host "[WARN] Payload exceeds Teams limit. Trimming file-status detail from summary."
        # Build-results page with the Artifacts tab — always derivable from variables
        # this script already has, regardless of what the actual published artifact
        # is named (that name is set by a PublishBuildArtifacts/PublishPipelineArtifact
        # task elsewhere in the pipeline YAML, which this script has no visibility into).
        # Linking to the results page itself, not a guessed artifact name, so the link
        # is always correct even if that downstream task's artifact name changes.
        $buildResultsUrl = "$collectionUri$teamProject/_build/results?buildId=$buildId&view=artifacts"
        $trimmedPayload = @{
            developer_email=$finalEmail; route_to_email=$routeToEmail; is_prod_fix=$isProdFix
            all_fix_ids=$allFixIds; org_name=$orgName; remediator_definition_id=$remediatorDefId
            build_id=$buildId; definition_id=$definitionId
            project_name=$teamProject; failed_branch=$cleanFailedBranch
            ai_summary="🔍 Found and fixed $($allFixes.Count) syntax error(s). Full detail: $buildResultsUrl"
            fixes=$webhookFixes; independent_fixes=$webhookFixes
        } | ConvertTo-Json -Depth 100 -Compress
        $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($trimmedPayload)

        # SECOND-STAGE FALLBACK: summary trimming alone assumed the fixes array
        # itself was small enough to always fit, but with enough fixes (each
        # carrying title/path/300-char old+new snippets) the array alone can
        # still exceed the limit. Re-measure, and if still too large, drop
        # fixes from the END of the WEBHOOK-ONLY array (never $artifactFixes —
        # the full-fidelity ai_fixes.json artifact the remediator reads is
        # built separately and is untouched by this) until it fits, noting how
        # many were omitted from the Teams card specifically.
        if ($payloadBytes.Length -gt 28672) {
            Write-Host "[WARN] Payload still exceeds Teams limit after summary trim — trimming fixes array for Teams card only."
            $cardFixes = [System.Collections.Generic.List[object]]::new($webhookFixes)
            while ($cardFixes.Count -gt 0 -and $payloadBytes.Length -gt 28672) {
                $cardFixes.RemoveAt($cardFixes.Count - 1)
                $omitted = $webhookFixes.Count - $cardFixes.Count
                $retryPayload = @{
                    developer_email=$finalEmail; route_to_email=$routeToEmail; is_prod_fix=$isProdFix
                    all_fix_ids=$allFixIds; org_name=$orgName; remediator_definition_id=$remediatorDefId
                    build_id=$buildId; definition_id=$definitionId
                    project_name=$teamProject; failed_branch=$cleanFailedBranch
                    ai_summary="🔍 Found and fixed $($allFixes.Count) syntax error(s). Showing $($cardFixes.Count) of them here ($omitted omitted for size). Full detail: $buildResultsUrl"
                    fixes=@($cardFixes); independent_fixes=@($cardFixes)
                } | ConvertTo-Json -Depth 100 -Compress
                $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($retryPayload)
            }
            if ($payloadBytes.Length -gt 28672) {
                Write-Host "[WARN] Payload still exceeds Teams limit even with zero fixes in the card — sending summary-only notification."
            }
        }
    }
    # Webhook dispatch — protected so Teams throttle/network error doesn't
    # crash the script before fix-memory is saved below.
    $webhookDispatched = $false
    $webhookAttempts   = 0
    do {
        $webhookAttempts++
        try {
            Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $payloadBytes `
                -ContentType "application/json" -TimeoutSec 300 -ErrorAction Stop
            $webhookDispatched = $true
        } catch {
            Write-Host "[WARN] Webhook attempt $webhookAttempts failed: $($_.Exception.Message)"
            # DIAGNOSTIC for "Invalid URI: The hostname could not be parsed" --
            # confirmed real failure mode (the .NET URI parser rejecting the
            # stored POWER_AUTOMATE_WEBHOOK value as not well-formed at all).
            # Reveals SHAPE info only (length, scheme prefix, whitespace) --
            # never the actual value, since that's a secret token-bearing URL
            # that must never appear in build logs.
            if ($_.Exception.Message -match '(?i)invalid uri|hostname could not be parsed') {
                $urlLen = $webhookUrl.Length
                $startsHttp = $webhookUrl -match '^https?://'
                $hasWhitespace = $webhookUrl -match '\s'
                Write-Host "[DIAG] POWER_AUTOMATE_WEBHOOK shape check (value itself NOT shown, to avoid leaking the secret): length=$urlLen, starts with http(s)://=$startsHttp, contains whitespace=$hasWhitespace."
                if (-not $startsHttp) { Write-Host "[DIAG] Likely cause: the stored value is missing the 'https://' prefix, or is empty/a placeholder -- check the ADO Library variable group." }
                if ($hasWhitespace) { Write-Host "[DIAG] Likely cause: the stored value has leading/trailing/embedded whitespace (e.g. a trailing newline from copy-paste) -- re-paste it carefully." }
            }
            if ($webhookAttempts -lt 2) { Start-Sleep -Seconds 5 }
        }
    } while (-not $webhookDispatched -and $webhookAttempts -lt 2)
    if (-not $webhookDispatched) {
        Write-Host "##vso[task.logissue type=warning]Webhook dispatch failed after $webhookAttempts attempt(s) — fixes are in artifact."
    }
    # Clean up temp files from syntax checking
    if (Test-Path $workRoot) { Remove-Item $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "[SUCCESS] Dispatched $($allFixes.Count) parser-verified fix(es)."
    $filesFixed = ($fileStatus | Where-Object { $_ -match '^✅' }).Count
    Write-Host "##vso[task.setvariable variable=AIFixCount;isOutput=true]$($allFixes.Count)"
    Write-Host "##vso[task.setvariable variable=AIFilesFixed;isOutput=true]$filesFixed"
    Write-Host "##vso[task.setvariable variable=AICallsUsed;isOutput=true]$($script:aiCallCount)"
    Write-Host "##vso[task.setvariable variable=AICleanFiles;isOutput=true]$($script:cleanFiles.Count)"
    Write-Host "[PERF] Total elapsed: $([int]$phaseStart.Elapsed.TotalSeconds)s | Files: $($processedPaths.Count) processed | Clean: $($script:cleanFiles.Count) | Fixed: $filesFixed | AI calls: $($script:aiCallCount) | Memory hits: $($script:memStats.hits) | Misses: $($script:memStats.misses) | TTL evicted: $($script:memStats.ttlEvicted)"

    # ── CROSS-RUN FIX MEMORY: SAVE with timestamps ─────────────────────────
    # ALWAYS save the memory artifact — even when empty ({}).
    # Previously only saved when Count > 0, which caused the artifact to
    # disappear on runs with 0 fixes. The next run then had nothing to load,
    # resetting all previously-learned signatures. Saving {} preserves artifact
    # continuity so the next run always finds something to load.
    try {
        $memDir = Join-Path $env:AGENT_TEMPDIRECTORY "AIMemory"
        New-Item -ItemType Directory -Force -Path $memDir | Out-Null
        $memJsonPath = Join-Path $memDir "fix_memory.json"
        $memObj = if ($null -ne $script:fixMemory) { $script:fixMemory } else { @{} }
        $memJson = ConvertTo-Json -InputObject $memObj -Depth 100 -Compress
        Set-Content -Path $memJsonPath -Value $memJson -Encoding UTF8

        # Analytics JSON — always written, shows 0s when nothing happened
        $analytics = @{
            run_date        = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            build_id        = $buildId
            definition_id   = $definitionId
            signatures      = $memObj.Count
            memory_hits     = [int]$script:memStats.hits
            memory_misses   = [int]$script:memStats.misses
            ttl_evicted     = [int]$script:memStats.ttlEvicted
            new_entries     = [int]$script:memStats.newEntries
            ai_calls        = [int]$script:aiCallCount
            files_processed = $processedPaths.Count
            plugin_fixes    = ($allFixes | Where-Object { $_.title -match 'Fastlane plugin' }).Count
            bundler_fixes   = ($allFixes | Where-Object { $_.title -match 'bundler error' }).Count
            top_signatures  = @(
                $memObj.GetEnumerator() |
                Sort-Object { [int]$_.Value.hits } -Descending |
                Select-Object -First 5 |
                ForEach-Object { @{ sig=$_.Key; hits=[int]$_.Value.hits; fails=[int]$_.Value.fails; lastUsed=$_.Value.lastUsed } }
            )
        }
        $analyticsPath = Join-Path $memDir "memory_analytics.json"
        Set-Content -Path $analyticsPath -Value ($analytics | ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8

        Write-Host "##vso[task.setvariable variable=AiMemoryPath]$memDir"
        Write-Host "[INFO] 🧠 Saved fix-memory: $($memObj.Count) signature(s) | hits: $($script:memStats.hits) | new: $($script:memStats.newEntries) | plugin fixes: $($analytics.plugin_fixes)"
    } catch { Write-Host "[INFO] Fix-memory save skipped: $($_.Exception.Message)" }

    # EXPLICIT exit 0: native tools (bash -n, node --check, python -m py_compile etc.)
    # leave $LASTEXITCODE = 1 after finding errors during syntax checking.
    # PowerShell exits with $LASTEXITCODE when the script ends normally — not with 0.
    # Without this, a successfully-completed triage run fails the ADO task with exit code 1.
    exit 0

} catch {
    $fatalStr = $_.Exception.Message
    Write-Host "##vso[task.logissue type=error]CRITICAL EXCEPTION: $fatalStr"
    $failsafe = @{ markdown_summary = "🚨 AI engine crashed. Manual investigation required.`n`nError: $fatalStr"; independent_fixes = @() }
    try {
        $artifactDir = Join-Path $env:AGENT_TEMPDIRECTORY "AIPayload"
        New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $artifactDir "ai_fixes.json"), ($failsafe | ConvertTo-Json -Depth 100 -Compress))
        Write-Host "##vso[task.setvariable variable=AiPayloadPath]$artifactDir"
    } catch {}
    try {
        $w2 = if ($env:POWER_AUTOMATE_WEBHOOK) { $env:POWER_AUTOMATE_WEBHOOK -replace '[\r\n\s]+', '' } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($w2)) {
            $fb = if (-not [string]::IsNullOrWhiteSpace($env:DEFAULT_ALERT_EMAIL)) { $env:DEFAULT_ALERT_EMAIL } else { "DevOps_Team_Fallback" }
            $sb = if ([string]::IsNullOrWhiteSpace($env:SYSTEM_PULLREQUEST_SOURCEBRANCH)) { $env:BUILD_SOURCEBRANCH } else { $env:SYSTEM_PULLREQUEST_SOURCEBRANCH }
            $cb = if (-not [string]::IsNullOrWhiteSpace($sb)) { $sb -replace '^refs/(heads|pull|tags)/', '' } else { "Unknown" }
            $ep = @{ developer_email=$fb; build_id=$env:BUILD_BUILDID; definition_id=$env:SYSTEM_DEFINITIONID; project_name=$env:SYSTEM_TEAMPROJECT; failed_branch=$cb; ai_summary=$failsafe.markdown_summary; fixes=@(); independent_fixes=@() } | ConvertTo-Json -Depth 100 -Compress
            Invoke-RestMethod -Uri $w2 -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($ep)) -ContentType "application/json; charset=utf-8" -TimeoutSec 30 -ErrorAction SilentlyContinue
        }
    } catch {}
    exit 1  # Explicit exit 1 on catch path so ADO marks the task as failed (correct behaviour)
}