# Windows Workstation Migration

**A resumable PowerShell workflow that moves a workstation to a new Active Directory domain and upgrades it to Windows 11.**

![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white) ![Active Directory](https://img.shields.io/badge/Active%20Directory-0078D4?logo=windows&logoColor=white)

Adapted from an endpoint migration I ran across **40 Windows workstations**. This portfolio edition uses illustrative domain and DNS settings and prompts for credentials at run time.

## The workflow

| Phase | What it does |
|---|---|
| **1. Join** | Stages installation files, configures DNS, checks Active Directory reachability and clock skew against the domain controller, then renames the machine and joins it to the target domain. |
| **2. Clean up and upgrade** | Resumes after the reboot, verifies the domain secure channel, cleans up local accounts and legacy profiles, then launches the Windows 11 upgrade. |
| **3. Verify** | Confirms the OS build and domain membership, installs the workstation application updater and records the result. |

## How it's built

- **Resumable state machine.** Progress is saved to a JSON state file. A scheduled task resumes the next phase at administrator logon after each reboot, and steps that are already done are skipped.
- **Pre-flight checks.** Fast TCP probes for domain controller ports, clock-skew measurement, an existing computer-account check and a pending-restart check, before anything changes.
- **Readable failures.** Domain-join error codes are translated into plain descriptions, and each failure stops with a diagnostic message.
- **Audit trail.** A full transcript, a log file and a per-phase OK/FAIL summary for every machine.
- **Verified steps.** Each change is checked after it runs (for example, that the scheduled task exists). Credentials come from `Get-Credential` and are never stored, and no environment-specific values are kept in the repository.

## Before running

Run it only in an isolated Windows lab first. The script changes DNS and domain membership, can disable the local administrator, delete a profile, reboot and upgrade Windows. Use an elevated Windows PowerShell 5.1 session, replace the example domain and DNS values, and supply your own approved Windows upgrade media and application installer.

The public edition was syntax-checked, but its full workflow has not been run outside the original environment.
