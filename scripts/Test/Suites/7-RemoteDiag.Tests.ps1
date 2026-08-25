#!/usr/bin/env pwsh
<#
Open ■
┬────┴  7-RemoteDiag.Tests
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Suites/7-RemoteDiag.Tests.ps1

.SYNOPSIS
    TSSH section 7 - Remote Diagnosis and Configuration.

.DESCRIPTION
    Dot-sourced by Invoke-Conformance.ps1, which then calls Invoke-KnxSuiteRemoteDiag.

    Clause 7.1.1 is the gate for this whole section. A device that does not advertise the
    "Remote Configuration and Diagnosis" service family is not required to implement any
    of it, so the remaining cases are reported N-A WITH THAT REASON rather than FAIL.
    That distinction matters for certification: an unimplemented optional service family
    is a declaration, not a defect - but it must appear in the report either way.

    Clause 7.5.9 Hard Reset is guarded twice (switch plus profile). TSSH section 1.5
    requires it to be run separately: it forces the device into factory configuration and
    the test client cannot restore the previous state - an ETS download is needed after.
#>

Set-StrictMode -Version Latest

function Test-RemoteDiagSilence {
    <#
    .SYNOPSIS
        Sends a malformed remote-diagnosis frame and returns whatever came back.
    #>
    param([string]$Ip, [int]$Port, [byte[]]$Frame, [int]$WindowMs = 1200)
    $s = New-KnxSocket -TimeoutMs $WindowMs
    try {
        Send-KnxFrame -Socket $s -Frame $Frame -Ip $Ip -Port $Port
        $got = @()
        $deadline = [DateTime]::UtcNow.AddMilliseconds($WindowMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
            $pkt = Receive-KnxFrame -Socket $s -TimeoutMs $left
            if ($null -eq $pkt) { break }
            $got += $pkt
        }
        return , $got
    }
    finally { $s.Dispose() }
}

function Invoke-KnxSuiteRemoteDiag {
    param([Parameter(Mandatory)]$Ctx, [string]$SuiteTitle = '7 Remote Diagnosis and Configuration')

    $K = Get-KnxConstants
    $ip = $Ctx.BdutIp
    $port = $Ctx.Port

    # ── 7.1.1 The gate ──────────────────────────────────────────────────────────

    # The gate is decided BEFORE the test case runs, not inside it: a verdict body must not
    # be the only place a later decision is computed - a skipped or failing body would
    # leave the flag undefined and silently change every following case.
    $desc = Get-KnxDescription -Ip $ip -Port $port
    $supported = $false
    if ($null -ne $desc) { $supported = Test-KnxFamilySupported -Body $desc.Body -Family $K.Family.REMOTE_CONF_DIAG }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-7.1.1' -Title 'Supported Service Family' -Clause 'TSSH 7.1.1, p.115' -Body {
        Assert-KnxTrue ($null -ne $desc) 'no description - the gate for section 7 cannot be decided'
        Add-KnxEvidence -Received $desc.Body -Note ("advertised: " + (($desc.Families | ForEach-Object { $_.Name }) -join ', '))
        # Neither answer is a failure: the family is optional. What matters is that the
        # device's behaviour later matches what it declares here.
        if ($supported) { Add-KnxEvidence -Note 'REMOTE_CONF_DIAG advertised - the full section applies' }
        else { Add-KnxEvidence -Note 'REMOTE_CONF_DIAG not advertised - the remaining cases are optional and reported N-A' }
    }

    # A device that does not advertise the family must also not answer its services.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-7.1.1b' -Title 'Behaviour matches the declaration' -Clause 'TSSH 7.1.1, p.115; 03_08_02 Core' -Body {
        $f = New-KnxRemoteDiagnosticRequest -DiscoveryIp '0.0.0.0' -DiscoveryPort 0 -Selector (New-KnxProgModeSelector)
        Add-KnxEvidence -Sent $f
        $got = Test-RemoteDiagSilence -Ip $ip -Port $port -Frame $f -WindowMs 1500
        if ($got.Count -gt 0) { Add-KnxEvidence -Received $got[0].Bytes }
        if ($supported) {
            Assert-KnxTrue ($got.Count -gt 0) 'device advertises REMOTE_CONF_DIAG but did not answer a REMOTE_DIAGNOSTIC_REQUEST'
        }
        else {
            Assert-KnxTrue ($got.Count -eq 0) 'device does NOT advertise REMOTE_CONF_DIAG but answered a REMOTE_DIAGNOSTIC_REQUEST - declaration and behaviour disagree'
        }
        Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after the remote-diagnosis probe'
    }

    # ── 7.1.2 - 7.1.4 malformed frames on the remote-diagnosis services ─────────

    $malformed = @(
        @{ Id = 'H-7.1.2'; Title = 'Illegal Service Code';    Clause = 'TSSH 7.1.2, p.116'; Mutate = 'service' },
        @{ Id = 'H-7.1.3'; Title = 'Illegal Header Length';   Clause = 'TSSH 7.1.3, p.117'; Mutate = 'header' },
        @{ Id = 'H-7.1.4'; Title = 'Illegal Protocol Version'; Clause = 'TSSH 7.1.4, p.118'; Mutate = 'version' }
    )
    foreach ($case in $malformed) {
        $mutate = $case.Mutate
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            # These stay meaningful even when the family is absent: a malformed frame must
            # never produce an answer and must never disturb the device.
            Add-KnxExpectedLog 'Unhandled KNX-IP service identifier: 740 or 74F, or nothing when the header itself is rejected'
            $f = New-KnxRemoteDiagnosticRequest -DiscoveryIp '0.0.0.0' -DiscoveryPort 0 -Selector (New-KnxProgModeSelector)
            switch ($mutate) {
                'service' { $f[2] = 0x07; $f[3] = 0x4F }
                'header'  { $f[0] = 0x01 }
                'version' { $f[1] = 0x11 }
            }
            Add-KnxEvidence -Sent $f
            $got = Test-RemoteDiagSilence -Ip $ip -Port $port -Frame $f
            if ($got.Count -gt 0) { Add-KnxEvidence -Received $got[0].Bytes }
            Assert-KnxTrue ($got.Count -eq 0) "device answered a malformed remote-diagnosis frame ($($got.Count) frame(s))"
            Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after the malformed frame'
        }
    }

    # ── 7.2 - 7.5: only meaningful when the family is advertised ────────────────

    $rest = @(
        @{ Id = 'H-7.2.1';  Title = 'REMOTE_DIAGNOSTIC_REQUEST - Illegal Total Length';        Clause = 'TSSH 7.2.1, p.119' },
        @{ Id = 'H-7.2.2';  Title = 'REMOTE_DIAGNOSTIC_REQUEST - Missing HPAI';                Clause = 'TSSH 7.2.2, p.120' },
        @{ Id = 'H-7.2.3';  Title = 'REMOTE_DIAGNOSTIC_REQUEST - Missing Selector';            Clause = 'TSSH 7.2.3, p.120' },
        @{ Id = 'H-7.2.4';  Title = 'REMOTE_DIAGNOSTIC_REQUEST - Illegal Selector';            Clause = 'TSSH 7.2.4, p.121' },
        @{ Id = 'H-7.2.5';  Title = 'REMOTE_DIAGNOSTIC_REQUEST - Selection by Programming Mode'; Clause = 'TSSH 7.2.5, p.122' },
        @{ Id = 'H-7.2.6';  Title = 'REMOTE_DIAGNOSTIC_REQUEST - Selection by MAC Address';     Clause = 'TSSH 7.2.6, p.124' },
        @{ Id = 'H-7.2.7';  Title = 'REMOTE_DIAGNOSTIC_REQUEST - Request via Broadcast';        Clause = 'TSSH 7.2.7, p.126' },
        @{ Id = 'H-7.3.1';  Title = 'Spontaneous REMOTE_DIAGNOSTIC_RESPONSE';                   Clause = 'TSSH 7.3.1, p.127' },
        @{ Id = 'H-7.3.2';  Title = 'REMOTE_DIAGNOSTIC_RESPONSE - Supported DIBs';              Clause = 'TSSH 7.3.2, p.128' },
        @{ Id = 'H-7.4.1';  Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - Illegal Total Length'; Clause = 'TSSH 7.4.1, p.129' },
        @{ Id = 'H-7.4.2';  Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - Missing HPAI';        Clause = 'TSSH 7.4.2, p.130' },
        @{ Id = 'H-7.4.3';  Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - Missing Selector';    Clause = 'TSSH 7.4.3, p.131' },
        @{ Id = 'H-7.4.4';  Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - Illegal Selector';    Clause = 'TSSH 7.4.4, p.132' },
        @{ Id = 'H-7.4.5';  Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - Selection by Programming Mode'; Clause = 'TSSH 7.4.5, p.133' },
        @{ Id = 'H-7.4.6';  Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - Selection by MAC Address'; Clause = 'TSSH 7.4.6, p.135' },
        @{ Id = 'H-7.4.7';  Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - Missing DIB';         Clause = 'TSSH 7.4.7, p.137' },
        @{ Id = 'H-7.4.8';  Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - Unknown DIB';         Clause = 'TSSH 7.4.8, p.138' },
        @{ Id = 'H-7.4.9';  Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - Device Information DIB'; Clause = 'TSSH 7.4.9, p.139' },
        @{ Id = 'H-7.4.10'; Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - Supported Service Families DIB'; Clause = 'TSSH 7.4.10, p.140' },
        @{ Id = 'H-7.4.11'; Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - IP Configuration DIB'; Clause = 'TSSH 7.4.11, p.141' },
        @{ Id = 'H-7.4.12'; Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - IP Current Configuration DIB'; Clause = 'TSSH 7.4.12, p.142' },
        @{ Id = 'H-7.4.13'; Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - KNX Addresses DIB';   Clause = 'TSSH 7.4.13, p.143' },
        @{ Id = 'H-7.4.14'; Title = 'REMOTE_BASIC_CONFIGURATION_REQUEST - Request via Broadcast'; Clause = 'TSSH 7.4.14, p.144' },
        @{ Id = 'H-7.5.1';  Title = 'REMOTE_RESET_REQUEST - Illegal Total Length';              Clause = 'TSSH 7.5.1, p.145' },
        @{ Id = 'H-7.5.2';  Title = 'REMOTE_RESET_REQUEST - Missing Selector';                  Clause = 'TSSH 7.5.2, p.146' },
        @{ Id = 'H-7.5.3';  Title = 'REMOTE_RESET_REQUEST - Illegal Selector';                  Clause = 'TSSH 7.5.3, p.147' },
        @{ Id = 'H-7.5.4';  Title = 'REMOTE_RESET_REQUEST - Selection by Programming Mode';     Clause = 'TSSH 7.5.4, p.148' },
        @{ Id = 'H-7.5.5';  Title = 'REMOTE_RESET_REQUEST - Selection by MAC Address';          Clause = 'TSSH 7.5.5, p.149' },
        @{ Id = 'H-7.5.6';  Title = 'REMOTE_RESET_REQUEST - Missing Reset Mode';                Clause = 'TSSH 7.5.6, p.150' },
        @{ Id = 'H-7.5.7';  Title = 'REMOTE_RESET_REQUEST - Unknown Reset Mode';                Clause = 'TSSH 7.5.7, p.151' },
        @{ Id = 'H-7.5.10'; Title = 'REMOTE_RESET_REQUEST - Request via Broadcast';             Clause = 'TSSH 7.5.10, p.154' }
    )

    foreach ($case in $rest) {
        $id = $case.Id
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $supported) {
                Set-KnxTestNotApplicable 'device does not advertise the Remote Configuration and Diagnosis service family (see H-7.1.1); the service is optional'
            }
            # The family IS advertised. These cases are deliberately NOT implemented: neither
            # OpenKNX product offers Remote Configuration and Diagnosis, so building 39 cases
            # for a service we do not ship would be work for a situation that never occurs.
            # Reported as N-A with that reason rather than as pending work - if a product ever
            # advertises the family, this line is where the decision gets revisited.
            Set-KnxTestNotApplicable "not implemented by decision: no OpenKNX product offers this service family. The device under test DOES advertise it, so case $id would have to be written before certifying THAT device"
        }
    }

    # ── 7.5.8 / 7.5.9 the two resets ────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-7.5.8' -Title 'REMOTE_RESET_REQUEST - Soft Reset' -Clause 'TSSH 7.5.8, p.152' -Body {
        if (-not $supported) { Set-KnxTestNotApplicable 'device does not advertise the Remote Configuration and Diagnosis service family (see H-7.1.1)' }
        if (-not $Ctx.AllowDestructive) { Set-KnxTestSkip 'restarts the device - needs -IncludeDestructive with profile Full' }

        # Reset mode 0x01 = soft reset (restart, configuration kept).
        $sel = New-KnxProgModeSelector
        $body = [byte[]]($sel + [byte[]]@(0x01, 0x00))
        $f = New-KnxFrame -Service $K.Service.REMOTE_RESET_REQUEST -Body $body
        Add-KnxEvidence -Sent $f
        $s = New-KnxSocket -TimeoutMs 2000
        try { Send-KnxFrame -Socket $s -Frame $f -Ip $ip -Port $port } finally { $s.Dispose() }

        Assert-KnxTrue (Wait-KnxGone -Ip $ip -TimeoutMs 20000) 'device never restarted after the soft reset request'
        Assert-KnxTrue (Wait-KnxBack -Ip $ip -TimeoutMs 90000) 'device did not come back within 90 s after the soft reset'
        Add-KnxEvidence -Note 'device restarted and came back'
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-7.5.9' -Title 'REMOTE_RESET_REQUEST - Hard Reset' -Clause 'TSSH 7.5.9, p.153 (see TSSH 1.5)' -Body {
        if (-not $supported) { Set-KnxTestNotApplicable 'device does not advertise the Remote Configuration and Diagnosis service family (see H-7.1.1)' }
        if (-not $Ctx.IncludeHardReset) {
            Set-KnxTestSkip 'forces factory configuration and needs an ETS download afterwards - run separately with -IncludeHardReset (TSSH 1.5)'
        }
        if (-not $Ctx.AllowDestructive) { Set-KnxTestSkip 'also needs -IncludeDestructive with profile Full' }

        # Reset mode 0x02 = factory reset.
        $sel = New-KnxProgModeSelector
        $body = [byte[]]($sel + [byte[]]@(0x02, 0x00))
        $f = New-KnxFrame -Service $K.Service.REMOTE_RESET_REQUEST -Body $body
        Add-KnxEvidence -Sent $f -Note 'FACTORY RESET issued - the device configuration is gone; an ETS download is required'
        $s = New-KnxSocket -TimeoutMs 2000
        try { Send-KnxFrame -Socket $s -Frame $f -Ip $ip -Port $port } finally { $s.Dispose() }

        Assert-KnxTrue (Wait-KnxGone -Ip $ip -TimeoutMs 20000) 'device never restarted after the hard reset request'
        # TSSH 1.5: the device may become unreachable at its old IP - that is not a failure
        # of the reset, so a missing return is reported, not asserted away.
        if (Wait-KnxBack -Ip $ip -TimeoutMs 90000) { Add-KnxEvidence -Note 'device returned at the same IP address' }
        else { Add-KnxEvidence -Note 'device did not return at the same IP address - expected after a factory reset without DHCP (TSSH 1.5)' }
    }
}
