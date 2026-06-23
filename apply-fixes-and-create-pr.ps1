$ErrorActionPreference = 'Stop'

# ── Analytics: set up path immediately so it's always published ──────────
# Written at every exit point (reject, no fixes, rollback, PR created).
# The publish task uses always() so it fires even on failure.
$analyticsDir = Join-Path $env:AGENT_TEMPDIRECTORY "AIAnalytics"
New-Item -ItemType Directory -Force -Path $analyticsDir -EA SilentlyContinue | Out-Null
$analyticsFile = Join-Path $analyticsDir "remediation_analytics.json"
function Write-Analytics {
    param([string]$reason, $prObj = $null, $applied = @(), $todos = 0, $rejected = "")
    try {
        $a = @{
            build_id      = "$env:FAILEDBUILDID"
            timestamp     = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            exit_reason   = $reason
            pr_id         = if ($prObj) { $prObj.pullRequestId } else { $null }
            pr_url        = if ($prObj) { $prObj.webUrl } else { $null }
            fixes_applied = @($applied)
            fixes_count   = @($applied).Count
            manual_todos  = $todos
            rejected_ids  = if ($rejected -and $rejected -ne 'none') { @($rejected -split ',') } else { @() }
            branch        = "$env:FAILEDBRANCHNAME"
        }
        # $analyticsFile is in the script scope — accessible directly (no $using: needed)
        [System.IO.File]::WriteAllText($analyticsFile, ($a | ConvertTo-Json -Depth 10 -Compress), [System.Text.Encoding]::UTF8)
    } catch {}
}
# Set variable immediately so the publish step always finds it
Write-Host "##vso[task.setvariable variable=AnalyticsPath]$analyticsDir"

if ("$env:USERACTION" -ne "approve_action") {
    Write-Host "🛑 Rejected by user."
    Write-Analytics -reason "rejected"
    exit 0
}

$branchPrefix = if ("$env:BRANCHPREFIX" -eq "") { "fix/ai-" } else { "$env:BRANCHPREFIX" }
$author       = if ("$env:AUTHORNAME" -eq "") { "AI-Remediation-Agent" } else { "$env:AUTHORNAME" }
$newAiBranch  = $branchPrefix + "$env:FAILEDBUILDID"
Write-Host "🚀 PR Branch: $newAiBranch"

Remove-Item -Path ".git/index.lock" -Force -ErrorAction SilentlyContinue
git clean -fd --exclude="AIFixPayload/"   # -fd only: preserve gitignored files (.env, build outputs)
$botEmail = if ("$env:BOTEMAIL" -ne "") { "$env:BOTEMAIL" } else { "ai-remediation@noreply.devops" }
git config --global user.email $botEmail  # Set BotEmail pipeline variable to override
git config --global user.name "$author"
git fetch origin
git checkout -B "$env:FAILEDBRANCHNAME" "origin/$env:FAILEDBRANCHNAME"
# -B = force-create: creates the fix branch if new, resets it to current HEAD if it
# already exists (e.g. a re-triggered run for the same build id). Without -B,
# git checkout -b silently exits non-zero on a re-run and execution continues on
# the wrong branch, committing onto $env:FAILEDBRANCHNAME instead of the fix branch.
git checkout -B "$newAiBranch"

$jsonPath = "$env:SYSTEM_DEFAULTWORKINGDIRECTORY/AIFixPayload/ai_fixes.json"
if (-not (Test-Path $jsonPath)) { Write-Error "❌ ai_fixes.json missing."; exit 1 }

$aiData   = Get-Content $jsonPath -Raw | ConvertFrom-Json
$rawIds   = ("$env:SELECTEDFIXIDS" -replace '[\[\]"]', '').Trim()
$selectAll = ($rawIds -ieq 'all' -or $rawIds -eq '*')
$ids      = if ($selectAll) { @() } else { $rawIds.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } }
$fixArray = if ($null -ne $aiData.independent_fixes) { $aiData.independent_fixes } else { $aiData.fixes }
if ($null -eq $fixArray -or @($fixArray).Count -eq 0) { Write-Host "🛑 No fixes."; Write-Analytics -reason "no_fixes"; exit 0 }
if (-not $selectAll -and $ids.Count -eq 0) { Write-Host "🛑 No fix IDs selected."; Write-Analytics -reason "no_ids_selected"; exit 0 }
if ($selectAll) { Write-Host "[INFO] All fixes selected (selectAll mode)." } else { Write-Host "[INFO] Selected fix IDs: $($ids -join ', ')" }

# ── Inline-bash-aware syntax oracle (mirrors the harvester) ───────────
$workRoot = Join-Path $env:AGENT_TEMPDIRECTORY "RemediatorChk"
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

# Ensure shellcheck (OS-aware: brew on macOS, apt on Linux); graceful fallback to bash -n.
$script:hasShellcheck = $false
$oldEAsc = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
if ($null -ne (Get-Command shellcheck -ErrorAction SilentlyContinue)) { $script:hasShellcheck = $true }
else {
    # NOTE: do NOT name these $isWindows / $isMacOS — they collide with the
    # read-only automatic variables $IsWindows / $IsMacOS in PowerShell Core
    # (case-insensitive) and throw "Cannot overwrite variable".
    # Check Windows FIRST (no uname dependency) so a missing uname on Windows
    # can't leave $onWindows unset and wrongly fall through to apt-get.
    $onWindows = ($IsWindows -or $env:OS -eq 'Windows_NT' -or $null -ne $env:WINDIR)
    $onMac     = $false
    if (-not $onWindows) {
        try { $onMac = ($IsMacOS -or (uname 2>$null) -eq 'Darwin') } catch { $onMac = $false }
    }
    if ($onMac) {
        if ($null -ne (Get-Command brew -EA SilentlyContinue)) {
            $jsc = Start-Job { brew install shellcheck 2>$null }; Wait-Job $jsc -Timeout 120 | Out-Null; Remove-Job $jsc -Force -EA SilentlyContinue
        }
    } elseif ($onWindows) {
        Write-Host "[INFO] Windows agent detected — shellcheck not auto-installed. bash -n remains the syntax floor."
        # Optional: choco install shellcheck -y (if Chocolatey is available)
        if ($null -ne (Get-Command choco -EA SilentlyContinue)) {
            $jsc = Start-Job { choco install shellcheck -y 2>$null }; Wait-Job $jsc -Timeout 120 | Out-Null; Remove-Job $jsc -Force -EA SilentlyContinue
        }
    } else {
        $jsc = Start-Job { sudo apt-get update -qq 2>$null; sudo apt-get install -y -qq shellcheck 2>$null }; Wait-Job $jsc -Timeout 120 | Out-Null; Remove-Job $jsc -Force -EA SilentlyContinue
    }
    if ($null -ne (Get-Command shellcheck -ErrorAction SilentlyContinue)) { $script:hasShellcheck = $true }
}
$ErrorActionPreference = $oldEAsc

# ── REAL-TOOL DETECTION (mirrors ai-triage-engine.ps1's fix) ──────────
# BUGFIX (real incident, confirmed via live test run): python3, bash,
# ruby, and node were called UNCONDITIONALLY at multiple call sites
# below with ZERO presence detection -- the identical bug class
# already found and fixed in ai-triage-engine.ps1 this session, except
# THIS script runs in a SEPARATE PowerShell@2 task with its own fresh
# process. Even when ai-triage-engine.ps1's task successfully installs
# Node/Python to a persistent folder, that install's $env:PATH change
# only ever affected ITS OWN process -- it does not carry over to this
# later, separate task. Confirmed real consequence: app.py's AI fixes
# (already verified correct and passing inside ai-triage-engine.ps1)
# were reported "❌ INVALID" here, not because the fix content was
# wrong, but because python3 in THIS task resolved to the same 0-byte
# Windows App-Execution-Alias stub that always prints a Microsoft
# Store redirect message and exits non-zero regardless of arguments --
# Get-Command finds the stub file and would have reported it present
# under the old (missing) check, same as the original bug.
#
# Fix: verify each tool by actually RUNNING it with --version and
# checking for a real digit in the output (a stub's redirect message
# has none) -- exactly Test-RealToolPresent's logic from
# ai-triage-engine.ps1. ALSO checks the same persistent
# $env:USERPROFILE\.triage-tools\<tool> folder ai-triage-engine.ps1
# installs into, prepending it to PATH if the binary is found there --
# this means a tool the triage task already installed on a PRIOR run
# is correctly found here too, without this task needing its own
# separate install logic or network access.
function Test-RealToolPresent {
    param([string]$Command, [string[]]$VersionArgs)
    if ($null -eq (Get-Command $Command -EA SilentlyContinue)) { return $false }
    try {
        $out = & $Command @VersionArgs 2>&1 | Out-String
        if ("$out" -match '\d') { return $true }
        return $false
    } catch { return $false }
}
foreach ($toolName in @('node','python')) {
    $persistedToolRoot = Join-Path $env:USERPROFILE ".triage-tools\$toolName"
    $persistedExe = if ($toolName -eq 'node') { Join-Path $persistedToolRoot 'node.exe' } else { Join-Path $persistedToolRoot 'python.exe' }
    if (Test-Path $persistedExe) {
        $env:PATH = "$persistedToolRoot;$env:PATH"
        Write-Host "[INFO] Found persisted $toolName install from a prior triage run at $persistedToolRoot — added to PATH for this task."
    }
}
$script:hasPython3 = Test-RealToolPresent -Command 'python3' -VersionArgs @('--version')
$script:hasNodeRT  = Test-RealToolPresent -Command 'node'    -VersionArgs @('--version')
$script:hasBashRT  = Test-RealToolPresent -Command 'bash'    -VersionArgs @('--version')
$script:hasRubyRT  = Test-RealToolPresent -Command 'ruby'    -VersionArgs @('--version')
# NEW: explicit detection for vue-tsc (used by the newly-ported
# Test-VueSyntax below) -- without this, $script:hasVueTsc would be
# undefined and PowerShell's undefined-variable-is-falsy behavior
# would happen to produce the correct fallback path anyway, but
# that's an implicit accident worth making explicit rather than
# relying on, exactly the same reasoning as every other tool flag.
$script:hasVueTsc = $null -ne (Get-Command 'vue-tsc' -EA SilentlyContinue)
Write-Host "[INFO] Remediator tool cache: python3=$($script:hasPython3) node=$($script:hasNodeRT) bash=$($script:hasBashRT) ruby=$($script:hasRubyRT)"

function Get-InlineScriptBlocks {
    param([string]$yamlContent)
    $lines = $yamlContent -split "\r?\n"; $blocks = @(); $i = 0
    while ($i -lt $lines.Count) {
        $isScript = ($lines[$i] -match '^(\s*)script:\s*\|')
        $isPwsh   = ($lines[$i] -match '^(\s*)(pwsh|powershell):\s*\|')
        if ($isScript -or $isPwsh) {
            $startIdx = $i + 1; $body = [System.Collections.Generic.List[string]]::new(); $ci = -1; $j = $startIdx
            $lookback = [Math]::Max(0, $i - 8)
            $preamble = ($lines[$lookback..$i] -join "`n")
            $isPowerShell = $isPwsh -or ($preamble -match '(?i)(PowerShell@\d|task:\s*PowerShell|pwsh:\s*true)')
            while ($j -lt $lines.Count) {
                $line = $lines[$j]
                if ($line.Trim() -eq '') { $body.Add(''); $j++; continue }
                $cur = ($line.Length - $line.TrimStart().Length)
                if ($ci -lt 0) { $ci = $cur }
                if ($cur -lt $ci) { break }
                $body.Add($(if ($line.Length -ge $ci) { $line.Substring($ci) } else { $line })); $j++
            }
            $bodyText = ($body -join "`n")
            if ($bodyText -match '(?im)(^\s*\$\w+\s*=|\bGet-Content\b|\bSet-Content\b|\$Env:|-replace\b|\bWrite-Host\b|\bInvoke-RestMethod\b|\bParam\s*\()') { $isPowerShell = $true }
            if ($bodyText -match '(?m)^\s*#!/usr/bin/env bash|^\s*#!/bin/(ba)?sh') { $isPowerShell = $false }
            $blocks += [PSCustomObject]@{ Body = $bodyText; Kind = $(if ($isPowerShell) { 'powershell' } else { 'bash' }) }
            $i = $j
        } else { $i++ }
    }
    return $blocks
}

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
        # BUGFIX: this originally called "Test-StructuralSyntax" (the
        # ENGINE's function name and richer {Ok,Message,Line} return
        # shape, carried over verbatim during the port) -- but the
        # remediator's equivalent function is named Test-StructuralOk
        # and returns a plain boolean instead. The original call would
        # have thrown a genuine CommandNotFoundException the moment
        # any .vue file with a <script> block reached this code path.
        $scrOk = (Test-StructuralOk $scriptMatch.Groups[1].Value $(if ($isTs) { 'ts' } else { 'js' }))
        if (-not $scrOk) {
            return @{Ok=$false;Message="Vue <script>: unclosed brace/paren/bracket or string literal in the <script> block";Line=$scriptLineOffset + 1}
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

function Test-StructuralOk {
    param([string]$content, [string]$lang)
    $lines=$content -split "`n"; $b=0; $p=0; $br=0; $inS=$false; $sC=''; $inBlk=$false; $lineNum=0
    foreach ($line in $lines) {
        $lineNum++; $inL=$false
        for ($i=0;$i -lt $line.Length;$i++) {
            $c=$line[$i]; $nx=if($i+1 -lt $line.Length){$line[$i+1]}else{''}
            if($inBlk){if($c -eq '*' -and $nx -eq '/'){$inBlk=$false;$i++};continue}
            if($inL){break}
            if($inS){if($c -eq '\' -and $lang -ne 'toml'){$i++;continue};if($c -eq $sC){$inS=$false};continue}
            if($c -eq '/' -and $nx -eq '/'){$inL=$true;break}
            if($c -eq '#' -and $lang -in @('python','ruby','sh','yaml','toml','hcl')){break}
            if($c -eq '/' -and $nx -eq '*'){$inBlk=$true;$i++;continue}
            if($c -in '"',"'"){$inS=$true;$sC=$c;continue}
            if($c -eq '`' -and $lang -in @('kotlin','js','ts','go')){$inS=$true;$sC='`';continue}
            if($c -eq '{'){$b++}elseif($c -eq '}'){$b--;if($b -lt 0){return $false}}
            elseif($c -eq '('){$p++}elseif($c -eq ')'){$p--;if($p -lt 0){return $false}}
            elseif($c -eq '['){$br++}elseif($c -eq ']'){$br--;if($br -lt 0){return $false}}
        }
    }
    # BUGFIX (found via deep audit, same gap confirmed and fixed in
    # ai-triage-engine.ps1's equivalent function): $inS was never
    # checked at end-of-content -- a genuinely unterminated quote/
    # backtick string running to the last line of the file was
    # silently treated as Ok. Every other delimiter already correctly
    # fails on imbalance; string termination was the one case with no
    # check at all.
    if ($inS) { return $false }
    return ($b -eq 0 -and $p -eq 0 -and $br -eq 0)
}

function Test-PowerShellOk {
    param([string]$scriptText)
    $tokens = $null; $errors = $null
    try { [System.Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$errors) | Out-Null }
    catch { return $false }
    return (-not ($null -ne $errors -and @($errors).Count -gt 0))
}

function Test-BashOk {
    param([string]$bf)
    if (-not $script:hasBashRT) {
        # BUGFIX: bash was called UNCONDITIONALLY here -- on this task's
        # own process (separate from ai-triage-engine.ps1's), bash
        # resolves to the same Windows App-Execution-Alias stub.
        # Falls back to structural checking (unclosed quotes/parens) --
        # narrower than real bash -n, but doesn't misreport a
        # genuinely-valid fix as broken because of a missing tool.
        try { $bashContent = [System.IO.File]::ReadAllText($bf) } catch { return $true }
        return (Test-StructuralOk $bashContent 'sh')
    }
    bash -n $bf 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    # SC1082 = UTF-8 BOM — suppress it here just as the triage does. The triage
    # already generates a dedicated BOM-removal fix (Strategy 0); the BOM does NOT
    # indicate a real script error and must not block validation of the real fixes.
    if ($script:hasShellcheck) { shellcheck -S error -e SC2154 -e SC2148 -e SC1082 $bf 2>$null; if ($LASTEXITCODE -ne 0) { return $false } }
    return $true
}

function Test-SyntaxOk {
    param([string]$filePath, [string]$content)
    $tmp = Join-Path $workRoot ("c_" + [System.IO.Path]::GetRandomFileName())
    $oldEA = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; $ok = $true
    # NEW: $script:lastSyntaxFailReason captures WHY validation failed,
    # for the checkers that already produce a real message
    # (Test-DockerfileSyntax, Test-KubernetesManifest) -- previously
    # every "❌ INVALID: $f" log line gave the bare filename with no
    # diagnostic at all, which is exactly what made the original
    # app.py false-positive (the pyflakes-stub bug from earlier this
    # session) genuinely hard to track down without reading the whole
    # script by hand. Reset to empty at the TOP of every call, before
    # this file's own checks run, so a stale reason from a PREVIOUS
    # file in the same validation loop can never be misattributed to
    # this one if this file's checker doesn't happen to set a reason.
    $script:lastSyntaxFailReason = ""
    try {
        if ($filePath -match '\.ya?ml$') {
            foreach ($b in (Get-InlineScriptBlocks -yamlContent $content)) {
                if ($b.Kind -eq 'powershell') { if (-not (Test-PowerShellOk $b.Body)){$ok=$false;break}; continue }
                # bash -n runs on RAW content (just checks bash syntax, ADO macros are valid command substitutions)
                $bf="$tmp.sh"; [System.IO.File]::WriteAllText($bf,$b.Body,[System.Text.Encoding]::UTF8)
                if ($script:hasBashRT) {
                    bash -n $bf 2>$null
                    if ($LASTEXITCODE -ne 0) { $ok=$false; Remove-Item $bf -Force -EA SilentlyContinue; break }
                } else {
                    # BUGFIX: bash was called UNCONDITIONALLY here -- on this
                    # task's own process (separate from ai-triage-engine.ps1's),
                    # bash resolves to the same Windows App-Execution-Alias
                    # stub. Structural fallback when bash genuinely isn't
                    # available. shellcheck below is NOT skipped just because
                    # bash is absent -- it's a static analyzer with no runtime
                    # dependency on bash itself, so it still gets to run
                    # independently when available.
                    if (-not (Test-StructuralOk $b.Body 'sh')) { $ok=$false; Remove-Item $bf -Force -EA SilentlyContinue; break }
                }
                if ($script:hasShellcheck) {
                    # Neutralize ADO macros BEFORE shellcheck — mirrors triage ConvertTo-ShellcheckSafe.
                    # Without this, shellcheck sees $env:BUILD_SOURCESDIRECTORY, $env:SYSTEM_ACCESSTOKEN etc.
                    # as unquoted command substitutions and reports ERROR-level violations even on
                    # syntactically correct scripts, causing atomic rollback of valid fixes.
                    $neutralized = $b.Body `
                        -replace '\$\((?:System\.|Build\.|Agent\.)[A-Za-z0-9_.]+\)', 'ADO_SYS_MACRO' `
                        -replace '\$\([A-Za-z_][A-Za-z0-9_.]*\)', 'ADO_VAR_MACRO' `
                        -replace '##vso\[[^\]]*\]', '# vso-logging-command'
                    $scf = "$tmp.sc.sh"
                    [System.IO.File]::WriteAllText($scf,$neutralized,[System.Text.Encoding]::UTF8)
                    shellcheck -S error -e SC2154 -e SC2148 -e SC1082 $scf 2>$null
                    $scOk = ($LASTEXITCODE -eq 0)
                    Remove-Item $scf -Force -EA SilentlyContinue
                    if (-not $scOk) { $ok=$false }
                }
                Remove-Item $bf -Force -EA SilentlyContinue; if (-not $ok){break}
            }
            # NEW: Kubernetes manifest check, runs AFTER the inline-
            # script-block loop above (which correctly no-ops for a
            # file with no script blocks, like deployment.yaml,
            # leaving $ok untouched at its default $true). BUGFIX of
            # my own first attempt: this was originally placed as a
            # SEPARATE "elseif ($filePath -match '\.ya?ml$' -and ...)"
            # branch below, which could NEVER be reached -- the FIRST
            # branch in this if/elseif chain already unconditionally
            # matches every .yaml/.yml file, so the elseif chain never
            # falls through to a second .yaml check. Moved inside the
            # SAME branch instead, gated by the same
            # Test-LooksLikeKubernetesManifest safety guard so it
            # still only fires on genuine K8s manifests, never on
            # Azure DevOps pipeline YAML (which has no "kind:" field).
            if ($ok -and (Test-LooksLikeKubernetesManifest -content $content)) {
                $k8sCheck = Test-KubernetesManifest -content $content
                $ok = $k8sCheck.Ok
                if (-not $ok) { $script:lastSyntaxFailReason = $k8sCheck.Message }
            }
        } elseif ($filePath -match '\.ps1$') { $ok=(Test-PowerShellOk $content) }
        elseif ($filePath -match '\.sh$') { $bf="$tmp.sh"; [System.IO.File]::WriteAllText($bf,$content,[System.Text.Encoding]::UTF8); $ok=(Test-BashOk $bf); Remove-Item $bf -Force -EA SilentlyContinue }
        elseif ($filePath -match '(?i)(Fastfile|Gemfile|\.rb)$') {
            if ($script:hasRubyRT) { $bf="$tmp.rb"; [System.IO.File]::WriteAllText($bf,$content); ruby -c $bf 2>$null; $ok=($LASTEXITCODE -eq 0); Remove-Item $bf -Force -EA SilentlyContinue }
            else { $ok=(Test-StructuralOk $content 'ruby') }   # BUGFIX: ruby was called unconditionally; see top-of-file note.
        }
        elseif ($filePath -match '\.py$') {
            if ($script:hasPython3) { $bf="$tmp.py"; [System.IO.File]::WriteAllText($bf,$content); python3 -m py_compile $bf 2>$null; $ok=($LASTEXITCODE -eq 0); Remove-Item $bf -Force -EA SilentlyContinue }
            else { $ok=(Test-StructuralOk $content 'python') }   # BUGFIX: python3 was called unconditionally; see top-of-file note. This is the EXACT bug confirmed via the live test that produced "❌ INVALID: app.py" for an already-correct fix.
        }
        elseif ($filePath -match '\.(js|ts|tsx|jsx)$') {
            if ($script:hasNodeRT) { $bf="$tmp.js"; [System.IO.File]::WriteAllText($bf,$content); node --check $bf 2>$null; $ok=($LASTEXITCODE -eq 0); Remove-Item $bf -Force -EA SilentlyContinue }
            else { $ok=(Test-StructuralOk $content 'js') }   # BUGFIX: node was called unconditionally; see top-of-file note.
        }
        elseif ($filePath -match '\.json$') {
            # Skip ADO/Adobe Analytics template files that use @varName@ syntax — not real JSON.
            if ($content.TrimStart().Length -gt 0 -and $content.TrimStart()[0] -ne '@') {
                try { $content | ConvertFrom-Json -Depth 100 -EA Stop | Out-Null } catch { $ok=$false }
            }
        }
        elseif ($filePath -match '(?i)\.(xml|csproj|plist|config|resx|props|targets)$') { try { [xml]$content | Out-Null } catch { $ok=$false } }
        elseif ($filePath -match '\.swift$') {
            if($null -ne (Get-Command swiftc -EA SilentlyContinue)){$bf="$tmp.swift";[System.IO.File]::WriteAllText($bf,$content);swiftc -parse $bf 2>$null;$ok=($LASTEXITCODE -eq 0);Remove-Item $bf -Force -EA SilentlyContinue}
            else{$ok=(Test-StructuralOk $content 'swift')}
        }
        elseif ($filePath -match '\.go$') {
            if($null -ne (Get-Command gofmt -EA SilentlyContinue)){$bf="$tmp.go";[System.IO.File]::WriteAllText($bf,$content);gofmt $bf 2>$null;$ok=($LASTEXITCODE -eq 0);Remove-Item $bf -Force -EA SilentlyContinue}
            else{$ok=(Test-StructuralOk $content 'go')}
        }
        elseif ($filePath -match '(?i)\.java$|build\.gradle$') {
            if($null -ne (Get-Command javac -EA SilentlyContinue)){$bf="$tmp.java";[System.IO.File]::WriteAllText($bf,$content);javac -nowarn $bf 2>$null;$ok=($LASTEXITCODE -eq 0);Remove-Item $bf -Force -EA SilentlyContinue}
            else{$ok=(Test-StructuralOk $content 'java')}
        }
        elseif ($filePath -match '(?i)\.(cs|vb|fs)$') { $ok=(Test-StructuralOk $content 'csharp') }
        elseif ($filePath -match '\.kts?$') {
            if($null -ne (Get-Command kotlinc -EA SilentlyContinue)){$bf="$tmp.kt";[System.IO.File]::WriteAllText($bf,$content);$null=(kotlinc $bf 2>$null);$ok=($LASTEXITCODE -eq 0);Remove-Item $bf -Force -EA SilentlyContinue}
            else{$ok=(Test-StructuralOk $content 'kotlin')}
        }
        elseif ($filePath -match '\.php$') {
            if($null -ne (Get-Command php -EA SilentlyContinue)){$bf="$tmp.php";[System.IO.File]::WriteAllText($bf,$content);php -l $bf 2>$null;$ok=($LASTEXITCODE -eq 0);Remove-Item $bf -Force -EA SilentlyContinue}
            else{$ok=(Test-StructuralOk $content 'php')}
        }
        elseif ($filePath -match '\.tf$|\.tfvars$') { $ok=(Test-StructuralOk $content 'hcl') }
        elseif ($filePath -match '(?i)\.groovy$|Jenkinsfile') {
            if($null -ne (Get-Command groovyc -EA SilentlyContinue)){
                $bf="$tmp.groovy";[System.IO.File]::WriteAllText($bf,$content);groovyc $bf 2>$null;$ok=($LASTEXITCODE -eq 0);Remove-Item $bf -Force -EA SilentlyContinue
            } else {
                # Groovy syntax (slashy strings, nested interpolation) is too complex for basic brace-counting.
                # If groovyc is missing, we must assume the structure is OK rather than throw a false positive.
                Write-Host "[INFO] groovyc not found — bypassing strict structural validation for $(Split-Path $filePath -Leaf)"
                $ok = $true
            }
        }
        elseif ($filePath -match '\.rs$') { $ok=(Test-StructuralOk $content 'rust') }
        # BUGFIX (real, pre-existing ordering bug, same class found and
        # fixed in ai-triage-engine.ps1): this MUST come before the
        # generic '\.toml$' branch below -- libs.versions.toml itself
        # ends in .toml, so the generic branch (checked first) would
        # always win and make this specific check permanently
        # unreachable, since PowerShell if/elseif chains stop at the
        # first true match.
        elseif ($filePath -match '(?i)(libs\.versions\.toml|version-catalog.*\.toml|gradle/libs\.versions)') {
            # Ported directly: Android version-catalog TOML breaks ALL
            # dependency resolution silently if malformed -- checks
            # unclosed strings and missing '=' in key-value pairs.
            $tomlLines = $content -split "\r?\n"
            for ($tl = 0; $tl -lt $tomlLines.Count; $tl++) {
                $tLine = $tomlLines[$tl].Trim()
                if ($tLine.StartsWith('#') -or [string]::IsNullOrWhiteSpace($tLine)) { continue }
                $qCount = ($tLine -replace "\\'",'').ToCharArray() | Where-Object { $_ -eq '"' } | Measure-Object | Select-Object -ExpandProperty Count
                if ($qCount % 2 -ne 0) { $ok=$false; $script:lastSyntaxFailReason = "libs.versions.toml: unclosed string on line $($tl+1)"; break }
                if ($tLine -notmatch '^\[' -and $tLine -notmatch '=' -and $tLine -notmatch '^#') { $ok=$false; $script:lastSyntaxFailReason = "libs.versions.toml: missing '=' in key-value on line $($tl+1)"; break }
            }
        }
        elseif ($filePath -match '\.toml$') { $ok=(Test-StructuralOk $content 'toml') }
        elseif ($filePath -match '\.dart$') { $ok=(Test-StructuralOk $content 'dart') }
        elseif ($filePath -match '(?i)Dockerfile') {
            if($null -ne (Get-Command hadolint -EA SilentlyContinue)){$bf="$tmp.Dockerfile";[System.IO.File]::WriteAllText($bf,$content);hadolint $bf 2>$null;$ok=($LASTEXITCODE -eq 0);Remove-Item $bf -Force -EA SilentlyContinue}
            else{
                # BUGFIX: Test-StructuralOk's generic brace/paren/bracket
                # check has no dockerfile-specific comment-character or
                # instruction-grammar awareness -- Dockerfiles don't use
                # {}/()/[] nesting the way it checks for, so this ALWAYS
                # silently returned $true regardless of actual content, a
                # structural no-op rather than a real check. Confirmed the
                # identical gap already found and fixed in
                # ai-triage-engine.ps1 this session -- ported the real,
                # purpose-built Test-DockerfileSyntax from there instead.
                $dockerCheck = Test-DockerfileSyntax -content $content
                $ok = $dockerCheck.Ok
                if (-not $ok) { $script:lastSyntaxFailReason = $dockerCheck.Message }
            }
        }
        # ── NEW: file types ai-triage-engine.ps1 already supports but
        # this dispatcher had NO branch for at all -- meaning a fix to
        # any of these file types previously fell through every elseif
        # and kept the function's default $ok=$true, passing with ZERO
        # validation regardless of actual content. Same class of gap as
        # the Dockerfile/Kubernetes fix above, just for more types.
        elseif ($filePath -match '(?i)(^|[/\\])Makefile$|\.mk$') {
            # Ported directly from ai-triage-engine.ps1: GNU make's
            # "missing separator" error fires when a recipe line uses
            # spaces instead of a literal TAB -- the #1 real-world
            # Makefile CI failure, pure text analysis, no toolchain.
            $mkLines = $content -split "\r?\n"
            $afterTarget = $false
            for ($mi = 0; $mi -lt $mkLines.Count; $mi++) {
                $ml = $mkLines[$mi]
                if ($ml -match '^[^\s#%].*:' -and $ml -notmatch '^\.PHONY|^vpath|^include') { $afterTarget = $true; continue }
                if ($afterTarget -and $ml -match '^( {2,}|\t)') {
                    if ($ml -match '^ ') { $ok=$false; $script:lastSyntaxFailReason = "Makefile: recipe line must start with TAB not spaces (missing separator error) on line $($mi+1)"; break }
                }
                if ([string]::IsNullOrWhiteSpace($ml) -or $ml.TrimStart().StartsWith('#')) { $afterTarget = $false }
            }
        }
        elseif ($filePath -match '(?i)(build\.gradle|settings\.gradle)$') {
            # Ported directly: structural groovy check + the two most
            # common real Android-Gradle DSL mistakes.
            if (-not (Test-StructuralOk $content 'groovy')) { $ok=$false }
            if ($ok) {
                $gradleLines = $content -split '\r?\n'
                for ($gi = 0; $gi -lt $gradleLines.Count; $gi++) {
                    $gl = $gradleLines[$gi]
                    if ($gl -match "^\s*implementation\s+[a-zA-Z][\w.]+:[a-zA-Z][\w.-]+:\d" -and $gl -notmatch '"') { $ok=$false; $script:lastSyntaxFailReason = "Gradle: dependency string must be quoted, line $($gi+1)"; break }
                    if ($gl -match '^\s*versionCode\s*=?\s*"') { $ok=$false; $script:lastSyntaxFailReason = "Gradle: versionCode must be an integer not a string, line $($gi+1)"; break }
                }
            }
        }
        elseif ($filePath -match '\.html?$') {
            $htmlCheck = Test-HtmlSyntax -content $content
            $ok = $htmlCheck.Ok
            if (-not $ok) { $script:lastSyntaxFailReason = $htmlCheck.Message }
        }
        elseif ($filePath -match '\.(css|scss|less|sass)$') {
            $cssCheck = Test-CssSyntax -content $content
            $ok = $cssCheck.Ok
            if (-not $ok) { $script:lastSyntaxFailReason = $cssCheck.Message }
        }
        elseif ($filePath -match '\.sql$') {
            $sqlCheck = Test-SqlSyntax -content $content
            $ok = $sqlCheck.Ok
            if (-not $ok) { $script:lastSyntaxFailReason = $sqlCheck.Message }
        }
        elseif ($filePath -match '\.vue$') {
            $vueCheck = Test-VueSyntax -content $content -filePath $filePath
            $ok = $vueCheck.Ok
            if (-not $ok) { $script:lastSyntaxFailReason = $vueCheck.Message }
        }
    } finally { $ErrorActionPreference = $oldEA }
    return $ok
}

# ── PHASE 1: apply selected fixes with re-validation guards ───────────
$fileBackups     = @{}
$filesToValidate = @{}
$appliedFixLog   = [System.Collections.Generic.List[string]]::new()
$skipLog         = [System.Collections.Generic.List[string]]::new()

# Sort fixes descending by line number so applying a fix never shifts the
# line numbers of remaining fixes (e.g. a fix that adds a line would push
# every subsequent line down by 1 — processing bottom-to-top avoids that).
# _fullContent fixes have line_number=0 and sort to the end, which is correct:
# full-file writes are independent and should run after all line edits.
$fixArray = @($fixArray | Sort-Object { [int]($_.line_number ?? 0) } -Descending)

foreach ($fix in $fixArray) {
    if (-not $selectAll -and $ids -notcontains $fix.fix_id.ToString()) { continue }
    if ($fix.new_code -match "INSERT_MANUAL_VALUE_HERE|MANUAL_INTERVENTION_REQUIRED") { $skipLog.Add("Fix $($fix.fix_id): needs manual value."); continue }
    if ($fix.new_code -match 'INSERT_ACTUAL_VALUE_HERE') { $skipLog.Add("Fix $($fix.fix_id): requires manual value insertion — skipped."); continue }

    # ── STRATEGY 00: Full-file manifest write ────────────────────────────
    # Dependency manifest fixes (requirements.txt, package.json, Gemfile, go.mod
    # etc.) store the ENTIRE new file content in _fullContent. Line-based strategies
    # would corrupt structured files (package.json: both old_code and new_code are
    # '}' → no-op skip; requirements.txt: Strategy 1 replaces last line instead of
    # appending). Write the full content directly and skip all other strategies.
    if (-not [string]::IsNullOrWhiteSpace($fix._fullContent)) {
        $abs = Join-Path "$env:BUILD_SOURCESDIRECTORY" $fix.file_path
        if (-not (Test-Path $abs)) { $skipLog.Add("Fix $($fix.fix_id): manifest file not found — $($fix.file_path)"); continue }
        if (-not $fileBackups.ContainsKey($abs)) { $fileBackups[$abs] = Get-Content $abs -Raw }
        [System.IO.File]::WriteAllText($abs, $fix._fullContent, [System.Text.Encoding]::UTF8)
        $filesToValidate[$abs] = $true
        $appliedFixLog.Add("Fix $($fix.fix_id): $($fix.file_path) — dependency manifest updated")
        Write-Host "➡️ Applied Fix $($fix.fix_id): updated $([IO.Path]::GetFileName($abs)) (full manifest write)"
        continue  # skip no-op check and line strategies — full content already written
    }

    # ── BOM FAST PATH (before no-op check) ──────────────────────────────
    # BOM removal fixes have old_code starting with \uFEFF. PowerShell's
    # .Trim() strips \uFEFF characters, so after normalization old_code and
    # new_code both reduce to the same plain text → the no-op check would
    # incorrectly skip the fix. Detect and apply via ReadAllBytes BEFORE the
    # no-op check can fire.
    if (([string]$fix.old_code).StartsWith([char]0xFEFF)) {
        $abs = Join-Path "$env:BUILD_SOURCESDIRECTORY" $fix.file_path
        if (-not (Test-Path $abs)) { $skipLog.Add("Fix $($fix.fix_id): BOM target file not found — $($fix.file_path)"); continue }
        if (-not $fileBackups.ContainsKey($abs)) { $fileBackups[$abs] = Get-Content $abs -Raw }
        $rawBytes = [System.IO.File]::ReadAllBytes($abs)
        if ($rawBytes.Count -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
            [System.IO.File]::WriteAllBytes($abs, $rawBytes[3..($rawBytes.Count - 1)])
            $filesToValidate[$abs] = $true
            $appliedFixLog.Add("Fix $($fix.fix_id): $($fix.file_path) — UTF-8 BOM stripped (binary I/O)")
            Write-Host "➡️ Applied Fix $($fix.fix_id): BOM removed from $([IO.Path]::GetFileName($abs))"
        } else {
            Write-Host "ℹ️ Fix $($fix.fix_id): no BOM bytes on disk — file already clean"
        }
        continue  # skip no-op check and line strategies; BOM path is complete
    }

    $oldNorm = ($fix.old_code -replace '\s+',' ').Trim(); $newNorm = ($fix.new_code -replace '\s+',' ').Trim()
    if ($oldNorm -eq $newNorm) { $skipLog.Add("Fix $($fix.fix_id): no-op skipped."); continue }

    $abs = Join-Path "$env:BUILD_SOURCESDIRECTORY" $fix.file_path
    if (-not (Test-Path $abs)) { $skipLog.Add("Fix $($fix.fix_id): file not found."); continue }
    if (-not $fileBackups.ContainsKey($abs)) { $fileBackups[$abs] = Get-Content $abs -Raw }

    $cleanNew = $fix.new_code.Trim()
    $lines = @(Get-Content $abs)  # @() forces array even for single-line files
    $applied = $false

    # ── STRATEGY 0: Binary BOM removal ──────────────────────────────────
    # Get-Content strips UTF-8 BOM when reading, so Strategies 1-3 can never
    # match old_code that starts with U+FEFF. When the triage synthesises a BOM
    # fix it deliberately sets old_code = BOM + line1 so we detect it here and
    # remove the 3 BOM bytes directly from the raw file bytes.
    if (-not $applied -and ([string]$fix.old_code).StartsWith([char]0xFEFF)) {
        try {
            $rawBytes = [System.IO.File]::ReadAllBytes($abs)
            if ($rawBytes.Count -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
                $noBom = $rawBytes[3..($rawBytes.Count - 1)]
                [System.IO.File]::WriteAllBytes($abs, $noBom)
                $filesToValidate[$abs] = $true
                $appliedFixLog.Add("Fix $($fix.fix_id): $($fix.file_path) — UTF-8 BOM removed (binary I/O)")
                $applied = $true
                Write-Host "➡️ Applied Fix $($fix.fix_id): removed UTF-8 BOM from $([IO.Path]::GetFileName($abs))"
            } else {
                $skipLog.Add("Fix $($fix.fix_id): BOM not present in file — already clean.")
                continue
            }
        } catch {
            $skipLog.Add("Fix $($fix.fix_id): BOM binary removal failed — $($_.Exception.Message)")
            continue
        }
    }

    # Strategy 1 (preferred): apply by line number, but ONLY if the live line still
    # matches the stored old_code (guards against a stale artifact after the branch moved).
    [int]$ln = 0
    if (-not $applied -and $null -ne $fix.line_number -and [int]::TryParse([string]$fix.line_number, [ref]$ln) -and $ln -ge 1 -and $ln -le $lines.Count) {
        $liveLine = $lines[$ln - 1]
        $liveNorm = ($liveLine -replace '\s+',' ').Trim()
        if ([string]::IsNullOrWhiteSpace($oldNorm) -or $liveNorm -eq $oldNorm) {
            $indent = ($liveLine -replace "^(\s*).*","`$1")
            $lines[$ln - 1] = $indent + $cleanNew
            $le1 = if ($fileBackups[$abs] -match "`r`n") { "`r`n" } else { "`n" }
            [System.IO.File]::WriteAllText($abs, ($lines -join $le1), [System.Text.Encoding]::UTF8)
            $filesToValidate[$abs] = $true; $appliedFixLog.Add("Fix $($fix.fix_id): $($fix.file_path) line $ln"); $applied = $true
            Write-Host "➡️ Applied Fix $($fix.fix_id) at line $ln"
        }
    }

    # Strategy 2: exact whitespace-normalized line match anywhere in the file.
    if (-not $applied -and -not [string]::IsNullOrWhiteSpace($oldNorm)) {
        $newLines = @(); $done = $false
        foreach ($line in $lines) {
            if (-not $done -and (($line -replace '\s+',' ').Trim() -eq $oldNorm)) {
                $newLines += (($line -replace "^(\s*).*","`$1") + $cleanNew); $done = $true
            } else { $newLines += $line }
        }
        if ($done) {
            $le2 = if ($fileBackups[$abs] -match "`r`n") { "`r`n" } else { "`n" }
            [System.IO.File]::WriteAllText($abs, ($newLines -join $le2), [System.Text.Encoding]::UTF8)
            $filesToValidate[$abs] = $true; $appliedFixLog.Add("Fix $($fix.fix_id): $($fix.file_path)"); $applied = $true
            Write-Host "➡️ Applied Fix $($fix.fix_id) (line match)"
        }
    }

    # Strategy 3: token-regex fallback.
    if (-not $applied -and -not [string]::IsNullOrWhiteSpace($fix.old_code)) {
        $content = Get-Content $abs -Raw
        $tokens = $fix.old_code -split '\s+' | Where-Object { $_ -match '\S' }
        $pattern = ($tokens | ForEach-Object { [regex]::Escape($_) }) -join '\s+'
        if ($content -match $pattern) {
            # Use an INSTANCE regex so the 3rd arg is a true replacement count (=1, first
            # match only). The static [regex]::Replace(...,1) would treat 1 as
            # RegexOptions.IgnoreCase and replace ALL matches case-insensitively.
            $reObj = [regex]::new($pattern)
            $newContent = $reObj.Replace($content, $cleanNew.Replace('$','$$'), 1)
            [System.IO.File]::WriteAllText($abs, $newContent, [System.Text.Encoding]::UTF8)
            $filesToValidate[$abs] = $true; $appliedFixLog.Add("Fix $($fix.fix_id): $($fix.file_path) (regex)"); $applied = $true
            Write-Host "➡️ Applied Fix $($fix.fix_id) (regex)"
        }
    }

    if (-not $applied) { $skipLog.Add("Fix $($fix.fix_id): could not locate target line (stale or moved).") }
}

if ($skipLog.Count -gt 0) { Write-Host "──── SKIPPED ────"; foreach ($s in $skipLog) { Write-Host "  ⚠️ $s" } }

# ── TODO PR: create checklist PR when all fixes need manual action ────
# When every fix has INSERT_MANUAL_VALUE_HERE, nothing is auto-applied but
# the developer still needs visibility. Create a PR with a markdown action
# plan so they get a notification and a concrete configuration checklist.
$manualTodos = $fixArray | Where-Object {
    ($selectAll -or $ids -contains $_.fix_id.ToString()) -and
    $_.new_code -match 'INSERT_MANUAL_VALUE_HERE|INSERT_ACTUAL_VALUE_HERE'
}
if ($filesToValidate.Count -eq 0 -and $manualTodos.Count -gt 0) {
    Write-Host "📋 $($manualTodos.Count) manual action(s) required — creating TODO checklist PR"
    $md  = "# ⚠️ Action Required — Build Failure Needs Manual Configuration`n`n"
    $md += "> **Build:** ``$env:FAILEDBUILDID`` | **Branch:** ``$env:FAILEDBRANCHNAME``  `n`n"
    $md += "The AI remediation agent detected $($manualTodos.Count) configuration issue(s) that cannot be auto-fixed.`n"
    $md += "Please configure the following in Azure DevOps pipeline settings, Library, or KeyVault:`n`n"

    $annotatedFiles = @{}  # track which files we've annotated so we can git add them

    foreach ($t in $manualTodos) {
        $md += "---`n"
        $md += "### $($t.title)`n`n"
        $parts = $t.new_code -split '\|'
        foreach ($part in $parts[1..($parts.Count-1)]) { $md += "- **$($part.Trim())**`n" }

        # If we know the exact file + line, add a code location callout AND annotate the file
        if ($t.file_path -ne 'ADO-pipeline-configuration' -and $t.line_number -gt 0) {
            $md += "`n**📍 Code location:** \`$($t.file_path)\` — Line $($t.line_number)`n"
            if (-not [string]::IsNullOrEmpty($t.old_code)) {
                $md += "``````ruby`n# Line $($t.line_number):`n$($t.old_code)`n```````n"
            }

            # Add an ACTION REQUIRED comment in the actual file at the exact line
            $abs = Join-Path "$env:BUILD_SOURCESDIRECTORY" $t.file_path
            if ((Test-Path $abs) -and -not $annotatedFiles.ContainsKey($abs)) {
                try {
                    $fileLines = [System.IO.File]::ReadAllLines($abs)
                    if ($t.line_number -ge 1 -and $t.line_number -le $fileLines.Count) {
                        $targetIdx = $t.line_number - 1
                        # Detect indentation from the target line
                        $indent = [regex]::Match($fileLines[$targetIdx], '^\s*').Value
                        # Build the comment — use # which works for Ruby, YAML, bash, PS
                        $varShort = ($t.new_code -split '\|')[1] -replace 'Variable:\s*','' -replace ' /.*','' | ForEach-Object { $_.Trim() }
                        $comment1 = "$indent# ⚠️ ACTION REQUIRED (AI-Remediation Build $env:FAILEDBUILDID): $varShort not configured — build failed here"
                        $comment2 = "$indent# 👉 See: .ai-remediation/build-$env:FAILEDBUILDID-action-required.md for setup instructions"
                        # Insert the 2 comment lines BEFORE the target line
                        $newLines = [System.Collections.Generic.List[string]]::new()
                        $newLines.AddRange([string[]]$fileLines[0..($targetIdx - 1)])
                        $newLines.Add($comment1)
                        $newLines.Add($comment2)
                        $newLines.AddRange([string[]]$fileLines[$targetIdx..($fileLines.Count - 1)])
                        [System.IO.File]::WriteAllLines($abs, $newLines, [System.Text.Encoding]::UTF8)
                        $annotatedFiles[$abs] = $true
                        Write-Host "📍 Annotated: $($t.file_path) line $($t.line_number)"
                    }
                } catch { Write-Host "[WARN] Could not annotate $($t.file_path): $($_.Exception.Message)" }
            }
        }
        $md += "`n"
    }

    $md += "---`n`n> ℹ️ Once configured, re-run the failed pipeline. Annotations in source files are for reference — remove after fixing.`n"

    $notesDir  = Join-Path "$env:BUILD_SOURCESDIRECTORY" ".ai-remediation"
    $notesFile = Join-Path $notesDir "build-$env:FAILEDBUILDID-action-required.md"
    New-Item -ItemType Directory -Force -Path $notesDir | Out-Null
    [System.IO.File]::WriteAllText($notesFile, $md, [System.Text.Encoding]::UTF8)

    git add "$notesFile"
    # Stage any annotated source files so the diff shows the exact lines
    foreach ($af in $annotatedFiles.Keys) { git add "$af"; Write-Host "📎 Staged for diff: $af" }
    git commit -m "⚠️ Action Required: $($manualTodos.Count) manual configuration item(s) for build $env:FAILEDBUILDID"
    git push origin HEAD:$newAiBranch
    if ($LASTEXITCODE -ne 0) {
        git push --force-with-lease origin HEAD:$newAiBranch
        # BUGFIX (found via exhaustive audit): the retry's own result was
        # never checked -- if BOTH pushes failed, execution silently
        # continued to PR creation below against a branch that may
        # never have actually been pushed at all.
        if ($LASTEXITCODE -ne 0) { throw "git push failed for the manual-action-only branch. Re-run or push manually before a PR can be created." }
    }

    $prTitle = "⚠️ Manual Action Required ($($manualTodos.Count) item(s)) — Build $env:FAILEDBUILDID"
    $prDesc  = "## Manual Configuration Checklist`n`n"
    foreach ($t in $manualTodos) { $prDesc += "- [ ] $($t.title -replace '^⚠️ MANUAL ACTION REQUIRED: ','')`n" }
    $prDesc += "`n> See \`.ai-remediation/build-$env:FAILEDBUILDID-action-required.md\` for full setup instructions."

    $prBody = @{
        sourceRefName = "refs/heads/$newAiBranch"
        targetRefName = "refs/heads/$env:FAILEDBRANCHNAME"
        title         = $prTitle
        description   = $prDesc
        isDraft       = $false
    } | ConvertTo-Json

    $prUrl = "$env:SYSTEM_COLLECTIONURI$env:SYSTEM_TEAMPROJECTID/_apis/git/repositories/$env:BUILD_REPOSITORY_ID/pullrequests?api-version=7.1"
    try {
        $prResp = Invoke-RestMethod -Uri $prUrl -Method Post -Body $prBody -ContentType "application/json" `
                  -Headers @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" } -ErrorAction Stop
        Write-Host "📋 TODO checklist PR created: $($prResp.webUrl)"
    } catch {
        if ($_.Exception.Response.StatusCode -eq 'Conflict') { Write-Host "📋 PR already exists. Branch updated with new checklist." }
        else { Write-Host "[WARN] PR creation failed: $($_.Exception.Message). Checklist committed to branch $newAiBranch" }
    }
    exit 0
}

if ($filesToValidate.Count -eq 0) {
    Write-Host "🛑 Nothing applied."
    Write-Analytics -reason "nothing_applied"
    exit 0
}

# ── PHASE 2: ATOMIC parser validation (inline-bash aware) ─────────────
$allValid = $true
foreach ($f in $filesToValidate.Keys) {
    $content = Get-Content $f -Raw
    if (Test-SyntaxOk -filePath $f -content $content) { Write-Host "✅ VALID: $f" }
    else {
        if (-not [string]::IsNullOrWhiteSpace($script:lastSyntaxFailReason)) {
            Write-Host "❌ INVALID: $f — $($script:lastSyntaxFailReason)"
        } else {
            Write-Host "❌ INVALID: $f"
        }
        $allValid = $false
    }
}
if (-not $allValid) {
    Write-Host "🛑 ATOMIC ROLLBACK: restoring ALL files. No PR."
    foreach ($f in $fileBackups.Keys) { [System.IO.File]::WriteAllText($f, $fileBackups[$f]) }

    # ── ROLLBACK SAFETY NET: even though code fixes failed, if manual TODOs
    # exist, still create a TODO-only PR so the developer sees the annotations ──
    if ($null -ne $manualTodos -and $manualTodos.Count -gt 0) {
        Write-Host "📋 Code fixes rolled back but $($manualTodos.Count) manual TODO(s) exist — creating TODO PR"
        # Reuse the TODO PR block: stage annotations + markdown, push, create PR
        $annotatedFiles2 = @{}
        $md2  = "# ⚠️ Action Required — Build Failure Needs Manual Configuration`n`n"
        $md2 += "> **Build:** ``$env:FAILEDBUILDID`` | **Branch:** ``$env:FAILEDBRANCHNAME`` *(code fixes rolled back — validation failed)*  `n`n"
        $md2 += "The AI remediation agent also detected $($manualTodos.Count) configuration issue(s) that require manual action:`n`n"
        foreach ($t in $manualTodos) {
            $md2 += "---`n### $($t.title)`n`n"
            $parts = $t.new_code -split '\|'
            foreach ($part in $parts[1..($parts.Count-1)]) { $md2 += "- **$($part.Trim())**`n" }
            if ($t.file_path -ne 'ADO-pipeline-configuration' -and $t.line_number -gt 0) {
                $md2 += "`n**📍 Location:** \`$($t.file_path)\` — Line $($t.line_number)`n"
                if (-not [string]::IsNullOrEmpty($t.old_code)) { $md2 += "``````yaml`n$($t.old_code)`n```````n" }
                $abs2 = Join-Path "$env:BUILD_SOURCESDIRECTORY" $t.file_path
                if ((Test-Path $abs2) -and -not $annotatedFiles2.ContainsKey($abs2)) {
                    try {
                        $fl2 = [System.IO.File]::ReadAllLines($abs2)
                        if ($t.line_number -ge 1 -and $t.line_number -le $fl2.Count) {
                            $idx2 = $t.line_number - 1
                            $ind2 = [regex]::Match($fl2[$idx2], '^\s*').Value
                            $varShort2 = ($t.new_code -split '\|')[1] -replace 'Variable:\s*','' -replace ' /.*','' | ForEach-Object { $_.Trim() }
                            $nl2 = [System.Collections.Generic.List[string]]::new()
                            $nl2.AddRange([string[]]$fl2[0..($idx2-1)])
                            $nl2.Add("$ind2# ⚠️ ACTION REQUIRED (AI-Remediation Build $env:FAILEDBUILDID): $varShort2 not configured")
                            $nl2.Add("$ind2# 👉 See .ai-remediation/build-$env:FAILEDBUILDID-action-required.md")
                            $nl2.AddRange([string[]]$fl2[$idx2..($fl2.Count-1)])
                            [System.IO.File]::WriteAllLines($abs2, $nl2, [System.Text.Encoding]::UTF8)
                            $annotatedFiles2[$abs2] = $true
                        }
                    } catch {}
                }
            }
            $md2 += "`n"
        }
        $nd2 = Join-Path "$env:BUILD_SOURCESDIRECTORY" ".ai-remediation"
        $nf2 = Join-Path $nd2 "build-$env:FAILEDBUILDID-action-required.md"
        New-Item -ItemType Directory -Force -Path $nd2 | Out-Null
        [System.IO.File]::WriteAllText($nf2, $md2, [System.Text.Encoding]::UTF8)
        git add "$nf2"
        foreach ($af2 in $annotatedFiles2.Keys) { git add "$af2" }
        git commit -m "⚠️ Action Required: $($manualTodos.Count) manual item(s) — code fixes rolled back for build $env:FAILEDBUILDID"
        git push origin HEAD:$newAiBranch
        if ($LASTEXITCODE -ne 0) {
            git push --force-with-lease origin HEAD:$newAiBranch
            # BUGFIX (found via exhaustive audit): same gap as the
            # manual-TODO-only path above -- the retry's result was
            # never checked, so a total push failure would silently
            # continue to PR creation against a possibly-unpushed branch.
            if ($LASTEXITCODE -ne 0) { throw "git push failed for the rollback branch. Re-run or push manually before a PR can be created." }
        }
        $pb2 = @{ sourceRefName="refs/heads/$newAiBranch"; targetRefName="refs/heads/$env:FAILEDBRANCHNAME"; title="⚠️ Manual Action Required ($($manualTodos.Count) item(s)) — Build $env:FAILEDBUILDID"; description=("## Manual Configuration Checklist`n`n" + ($manualTodos | ForEach-Object { "- [ ] $($_.title -replace '^⚠️ MANUAL ACTION REQUIRED: ','')" } | Out-String)) } | ConvertTo-Json
        $pu2 = "$env:SYSTEM_COLLECTIONURI$env:SYSTEM_TEAMPROJECTID/_apis/git/repositories/$env:BUILD_REPOSITORY_ID/pullrequests?api-version=7.1"
        try { $r2 = Invoke-RestMethod -Uri $pu2 -Method Post -Body $pb2 -ContentType "application/json" -Headers @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" } -EA Stop; Write-Host "📋 Fallback TODO PR created: $($r2.webUrl)" }
        catch { Write-Host "[WARN] Fallback TODO PR: $($_.Exception.Message)" }
    }
    Write-Analytics -reason "rollback_validation_failed"
    Write-Error "Validation failed — all code changes rolled back."
    exit 1
}

# ── PHASE 3: commit + push + PR ───────────────────────────────────────
Write-Host "✅ All $($filesToValidate.Count) file(s) parser-valid. Committing."
# Stage ONLY the files the agent modified — not all tracked changes
$filesToValidate.Keys | ForEach-Object { git add "$_" }

# ── Include manual TODO annotations in the SAME PR when code fixes also apply ──
# This gives the developer one PR showing both: the code fix diff AND the exact
# location of every credential/secret that needs manual configuration.
$todoDesc = ''
if ($null -ne $manualTodos -and $manualTodos.Count -gt 0) {
    Write-Host "📋 Adding $($manualTodos.Count) manual TODO annotation(s) to this PR..."
    $todoAnnotated = @{}
    $todoMd  = "# ⚠️ Manual Configuration Required`n`n"
    $todoMd += "> **Build:** ``$env:FAILEDBUILDID`` | **Branch:** ``$env:FAILEDBRANCHNAME``  `n`n"
    $todoMd += "$($manualTodos.Count) issue(s) below require manual configuration. The code fix above was applied automatically.`n`n"
    foreach ($t in $manualTodos) {
        $todoMd += "---`n### $($t.title)`n`n"
        $tparts = $t.new_code -split '\|'
        foreach ($tp in $tparts[1..($tparts.Count-1)]) { $todoMd += "- **$($tp.Trim())**`n" }
        if ($t.file_path -ne 'ADO-pipeline-configuration' -and $t.line_number -gt 0) {
            $todoMd += "`n**📍 Location:** \`$($t.file_path)\` — Line $($t.line_number)`n"
            if (-not [string]::IsNullOrEmpty($t.old_code)) { $todoMd += "``````yaml`n$($t.old_code)`n```````n" }
            $tabs = Join-Path "$env:BUILD_SOURCESDIRECTORY" $t.file_path
            if ((Test-Path $tabs) -and -not $todoAnnotated.ContainsKey($tabs)) {
                try {
                    $tfl = [System.IO.File]::ReadAllLines($tabs)
                    if ($t.line_number -ge 1 -and $t.line_number -le $tfl.Count) {
                        $tidx = $t.line_number - 1
                        $tind = [regex]::Match($tfl[$tidx], '^\s*').Value
                        $tvs  = ($t.new_code -split '\|')[1] -replace 'Variable:\s*','' -replace ' /.*','' | ForEach-Object { $_.Trim() }
                        $tnl  = [System.Collections.Generic.List[string]]::new()
                        $tnl.AddRange([string[]]$tfl[0..($tidx-1)])
                        $tnl.Add("$tind# ⚠️ ACTION REQUIRED (AI-Remediation Build $env:FAILEDBUILDID): $tvs not configured — build failed here")
                        $tnl.Add("$tind# 👉 See .ai-remediation/build-$env:FAILEDBUILDID-action-required.md for setup instructions")
                        $tnl.AddRange([string[]]$tfl[$tidx..($tfl.Count-1)])
                        [System.IO.File]::WriteAllLines($tabs, $tnl, [System.Text.Encoding]::UTF8)
                        $todoAnnotated[$tabs] = $true
                        Write-Host "📍 Annotated: $($t.file_path) line $($t.line_number)"
                    }
                } catch { Write-Host "[WARN] Could not annotate $($t.file_path): $($_.Exception.Message)" }
            }
        }
        $todoMd += "`n"
    }
    $todoMd += "---`n`n> ℹ️ Remove the ACTION REQUIRED comments after fixing. This PR can be merged as-is (code fix only) or after configuring.`n"
    $tnd = Join-Path "$env:BUILD_SOURCESDIRECTORY" ".ai-remediation"
    $tnf = Join-Path $tnd "build-$env:FAILEDBUILDID-action-required.md"
    New-Item -ItemType Directory -Force -Path $tnd | Out-Null
    [System.IO.File]::WriteAllText($tnf, $todoMd, [System.Text.Encoding]::UTF8)
    git add "$tnf"
    foreach ($ta in $todoAnnotated.Keys) { git add "$ta"; Write-Host "📎 Staged: $ta" }
    $todoDesc = "`n`n---`n## ⚠️ Manual Actions Also Required`n`n" + ($manualTodos | ForEach-Object { "- [ ] $($_.title -replace '^⚠️ MANUAL ACTION REQUIRED: ','')" } | Out-String)
}
git commit -m "🤖 AI Auto-Remediation: Applied fix IDs $rawIds"
git push origin HEAD:$newAiBranch
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] Push rejected (branch may already exist). Retrying with --force-with-lease..."
    git push --force-with-lease origin HEAD:$newAiBranch
    if ($LASTEXITCODE -ne 0) { throw "git push failed. Branch may have diverged. Re-run or push manually." }
}

$prUrl  = "$env:SYSTEM_COLLECTIONURI$env:SYSTEM_TEAMPROJECTID/_apis/git/repositories/$env:BUILD_REPOSITORY_ID/pullrequests?api-version=7.1"

# ── DUPLICATE PR CHECK: prevent double-PR if remediator runs twice ────
$existingPrUrl = "$prUrl&sourceRefName=refs/heads/$newAiBranch&status=active"
$existingPrUrl = "$prUrl&searchCriteria.sourceRefName=refs/heads/$newAiBranch&searchCriteria.status=active"
try {
    $existingPrs = Invoke-RestMethod -Uri $existingPrUrl -Method Get -Headers @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" } -EA Stop
    if ($null -ne $existingPrs -and $existingPrs.count -gt 0) {
        Write-Host "✅ PR already exists for branch $newAiBranch (ID: $($existingPrs.value[0].pullRequestId)) — updating branch only."
        # BUGFIX (found via exhaustive audit): this push previously had
        # NO error checking at all -- unlike the established, correct
        # pattern used for the main push just above this block (retry
        # with --force-with-lease, throw on total failure). A silent
        # failure here would have reported success (exit 0,
        # "duplicate_pr_branch_updated") even though the existing PR's
        # branch was never actually updated with the latest fixes.
        git push --force-with-lease origin HEAD:$newAiBranch
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[WARN] Duplicate-PR branch update push failed. Retrying once..."
            git push --force-with-lease origin HEAD:$newAiBranch
            if ($LASTEXITCODE -ne 0) { throw "git push failed while updating existing PR's branch. The PR exists but does NOT contain the latest fixes -- re-run or push manually." }
        }
        Write-Analytics -reason "duplicate_pr_branch_updated"
        exit 0
    }
} catch { Write-Host "[INFO] Duplicate PR check skipped: $($_.Exception.Message)" }

$prBody = @{
    sourceRefName = "refs/heads/$newAiBranch"; targetRefName = "refs/heads/$env:FAILEDBRANCHNAME"
    title = "🤖 AI Triage: Fixes for Build $env:FAILEDBUILDID"
    description = "Automated PR — all fixes parser-validated and applied atomically.`n`nApplied:`n" + ($appliedFixLog -join "`n") + $todoDesc
} | ConvertTo-Json

try {
    $pr = Invoke-RestMethod -Uri $prUrl -Method Post -Body $prBody -ContentType "application/json" -Headers @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" } -ErrorAction Stop
    if (Test-Path $workRoot) { Remove-Item $workRoot -Recurse -Force -EA SilentlyContinue }
    Write-Host "🔗 PR CREATED (ID: $($pr.pullRequestId))."
    $rev = "$env:REVIEWEREMAIL"
    if (-not [string]::IsNullOrWhiteSpace($rev) -and $rev -notmatch "Fallback") {
        try {
            $idu = "${env:SYSTEM_COLLECTIONURI}_apis/identities?searchFilter=General&filterValue=$([uri]::EscapeDataString($rev))&api-version=7.1"
            $id = Invoke-RestMethod -Uri $idu -Method Get -Headers @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" } -ErrorAction Stop
            if ($null -ne $id.value -and $id.value.Count -gt 0) {
                $rid = $id.value[0].id
                $ru = "$env:SYSTEM_COLLECTIONURI$env:SYSTEM_TEAMPROJECTID/_apis/git/repositories/$env:BUILD_REPOSITORY_ID/pullRequests/$($pr.pullRequestId)/reviewers/$rid" + "?api-version=7.1"
                Invoke-RestMethod -Uri $ru -Method Put -Body (@{ vote = 0; id = $rid } | ConvertTo-Json) -ContentType "application/json" -Headers @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" } -EA Stop | Out-Null
                Write-Host "👤 Added $rev as reviewer."
            }
        } catch { Write-Host "[WARN] Reviewer add failed: $($_.Exception.Message)" }
    }

    # ── AUTO-FLAG: comment (do NOT abandon) if fix may already exist in target branch ──
    # Detection logic unchanged from the original auto-close check: same comparison,
    # same condition. Only the ACTION changed — this now posts a visible review
    # comment on the PR instead of silently closing it, so the decision of whether
    # the PR is actually redundant stays with the developer, not the script.
    try {
        $firstFix = $fixArray | Where-Object { $appliedFixLog -match $_.fix_id } | Select-Object -First 1
        if ($null -ne $firstFix -and -not [string]::IsNullOrWhiteSpace($firstFix.old_code)) {
            $targetFileUrl = "$env:SYSTEM_COLLECTIONURI$env:SYSTEM_TEAMPROJECTID/_apis/git/repositories/$env:BUILD_REPOSITORY_ID/items?path=$([uri]::EscapeDataString($firstFix.file_path))&versionDescriptor.versionType=branch&versionDescriptor.version=$env:FAILEDBRANCHNAME&api-version=7.1"
            $targetContent = Invoke-RestMethod -Uri $targetFileUrl -Method Get -Headers @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" } -EA Stop
            if (-not [string]::IsNullOrWhiteSpace($targetContent) -and -not ($targetContent -match [regex]::Escape($firstFix.old_code.Trim()))) {
                Write-Host "⚠️ Fix may already be applied to target branch — flagging for developer review (not auto-closing)."
                $warnBody = @{
                    comments = @(@{
                        content     = "⚠️ **Heads up:** the original issue this PR was meant to fix (``$($firstFix.file_path)``) may already be present in ``$env:FAILEDBRANCHNAME``. Please verify there's a real diff before merging — this PR was left active for you to review and decide whether it's still needed."
                        commentType = 1
                    })
                    status = 1
                } | ConvertTo-Json -Depth 5
                $threadUrl = "$env:SYSTEM_COLLECTIONURI$env:SYSTEM_TEAMPROJECTID/_apis/git/repositories/$env:BUILD_REPOSITORY_ID/pullRequests/$($pr.pullRequestId)/threads?api-version=7.1"
                Invoke-RestMethod -Uri $threadUrl -Method Post -Body $warnBody -ContentType "application/json" -Headers @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" } -EA SilentlyContinue | Out-Null
                Write-Host "✅ Review comment added (PR stays active)."
            }
        }
    } catch { Write-Host "[INFO] Auto-flag check skipped: $($_.Exception.Message)" }

} catch {
    if ($_.Exception.Response.StatusCode -eq 'Conflict') { Write-Host "✅ PR already exists. Branch updated." }
    else { throw $_ }
}

# ── REJECTION MEMORY UPDATE ────────────────────────────────────────────
# When a developer rejects fixes in the Teams card, the Logic App passes
# the rejected fix IDs here. We use this as negative signal: increment
# fails for those signatures, evict at fails >= 2. This is the strongest
# signal that a cached fix is wrong.
$rejectedRaw = "$env:REJECTEDFIXIDS"
if (-not [string]::IsNullOrWhiteSpace($rejectedRaw) -and $rejectedRaw -ne 'none') {
    Write-Host "👎 Processing $($rejectedRaw -split ',' | Measure-Object).Count rejected fix ID(s) as negative memory signal..."
    $rejectedIds = $rejectedRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    foreach ($rjId in $rejectedIds) {
        $rjFix = $fixArray | Where-Object { "$($_.fix_id)" -eq $rjId } | Select-Object -First 1
        if ($null -ne $rjFix -and -not [string]::IsNullOrWhiteSpace($rjFix.old_code)) {
            # Re-download memory artifact to update rejection counts
            Write-Host "  👎 Fix $rjId rejected by developer — marking as negative signal in memory"
            # The actual memory file update happens in the triage's next run via the published artifact
            # We publish a "rejection record" artifact that the triage reads on next run
        }
    }
    # Publish rejection record for triage to consume
    $rejDir = Join-Path "$env:BUILD_SOURCESDIRECTORY" ".ai-remediation"
    New-Item -ItemType Directory -Force -Path $rejDir | Out-Null
    $rejRecord = @{
        build_id       = "$env:FAILEDBUILDID"
        rejected_ids   = @($rejectedIds)
        timestamp      = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $rejDir "rejection_record.json"), $rejRecord, [System.Text.Encoding]::UTF8)
    Write-Host "📝 Rejection record saved — triage will update memory on next run."
}

# ── Write analytics at successful PR creation exit ─────────────────────
Write-Analytics -reason "pr_created" -prObj $pr -applied $appliedFixLog -todos ($manualTodos ? $manualTodos.Count : 0) -rejected $rejectedRaw
Write-Host "📊 Analytics written."