#!/usr/bin/env pwsh
# Open ■
# ┬────┴  8-IpMedium.Tests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Suites/8-IpMedium.Tests.ps1

<#
.SYNOPSIS
    TSSH section 8 - IP as KNX Medium.

.DESCRIPTION
    Dot-sourced by Invoke-Conformance.ps1, which then calls Invoke-KnxSuiteIpMedium.

    This section applies to KNX IP END DEVICES, which clause 8.2.2 identifies by mask
    version 57B0h or 5705h. Neither product here is one: the IP-Interface is 07B0 (a TP1
    System B device with a KNXnet/IP front end) and the IP-Router is 091A (a coupler).

    The cases are therefore reported N-A - but they ARE reported, each with its reason and
    the observed mask version. An omitted case looks like an oversight in a certification
    report; a case marked N-A with evidence is a documented decision. The mask is read from
    the device rather than assumed, so if a product ever moves to 57B0 this suite starts
    demanding real implementations instead of silently staying N-A.
#>

Set-StrictMode -Version Latest

function Invoke-KnxSuiteIpMedium {
    param([Parameter(Mandatory)]$Ctx, [string]$SuiteTitle = '8 IP as KNX Medium')

    $K = Get-KnxConstants
    $ip = $Ctx.BdutIp
    $port = $Ctx.Port

    # Read the mask rather than trusting the build flags: this is the only thing that
    # decides whether the section applies. The DESCRIPTION_RESPONSE is NOT the source -- 03_08_02
    # Table 5 p.31 forbids the Extended Device Information DIB there, so reading the mask from it
    # left every case here N-A for "unknown" and would hide a mis-detected 57B0 device. PID 83 is
    # the source; the DIB is only cross-checked below when the mask says IP medium.
    $desc = Get-KnxDescription -Ip $ip -Port $port
    $maskRaw = Get-KnxMaskVersion -Ip $ip -Port $port
    $mask = if ($null -ne $maskRaw) { $maskRaw } else { 'not readable (PID 83 unanswered)' }
    $isIpDevice = (@('0x57B0', '0x5705') -contains $mask)

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-8.2.2' -Title 'Detection of Mask Version (57B0h or 5705h)' -Clause 'TSSH 8.2.2, p.156' -Body {
        Assert-KnxTrue ($null -ne $desc) 'no description'
        Add-KnxEvidence -Note "mask version $mask"
        if (-not $isIpDevice) {
            Set-KnxTestNotApplicable "mask version $mask is not a KNX IP end device (57B0h/5705h); section 8 does not apply to this product"
        }
        # No DIB is demanded here: the same clause that names PID 83 authoritative forbids the
        # Extended Device Information DIB in a DESCRIPTION_RESPONSE, so requiring it would fail a
        # conformant device. When the device does send one anyway, it must agree with PID 83.
        # $desc is null when the device did not answer the DESCRIPTION_REQUEST at all, and under
        # Set-StrictMode -Version Latest reading a property off it throws instead of yielding null.
        if ($null -ne $desc -and $null -ne $desc.Extended) {
            Assert-KnxEqual $mask $desc.Extended.MaskVersion 'Extended Device Information DIB and PID 83 report different mask versions'
        }
    }

    $rest = @(
        @{ Id = 'H-8.2.1'; Title = 'Detection of KNX IP end devices';       Clause = 'TSSH 8.2.1, p.155' },
        @{ Id = 'H-8.3.1'; Title = 'cEMI Device Management Version 2';      Clause = 'TSSH 8.3.1, p.157' },
        @{ Id = 'H-8.3.2'; Title = 'cEMI T_Connect / T_Disconnect';         Clause = 'TSSH 8.3.2, p.158' },
        @{ Id = 'H-8.3.3'; Title = 'cEMI T_Data_Broadcast';                 Clause = 'TSSH 8.3.3, p.159' },
        @{ Id = 'H-8.3.4'; Title = 'cEMI T_Data_Group';                     Clause = 'TSSH 8.3.4, p.160' },
        @{ Id = 'H-8.3.5'; Title = 'cEMI T_Data_Connected';                 Clause = 'TSSH 8.3.5, p.161' },
        @{ Id = 'H-8.3.6'; Title = 'cEMI T_Data_Individual';                Clause = 'TSSH 8.3.6, p.163' }
    )

    foreach ($case in $rest) {
        $id = $case.Id
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $isIpDevice) {
                Set-KnxTestNotApplicable "device mask version is $mask, not a KNX IP end device (57B0h/5705h) - section 8 does not apply"
            }
            # Deliberately not implemented: section 8 applies to KNX IP end devices (mask
            # 57B0h/5705h). The IP-Interface is 07B0 and the IP-Router 091A, so no OpenKNX
            # product can ever reach this branch.
            Set-KnxTestNotApplicable "not implemented by decision: no OpenKNX product uses an IP-medium mask. This device reports $mask, so case $id would have to be written before certifying THAT device"
        }
    }
}
