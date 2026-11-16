# Windows Workstation Migration

A PowerShell workflow adapted from an endpoint migration deployed across 40 Windows workstations. This portfolio edition uses illustrative domain and DNS settings and prompts for migration credentials in Phase 1.

1. Stage installation files, configure DNS, check Active Directory connectivity and clock skew, then rename and join the workstation to the target domain.
2. Resume after reboot, verify the domain secure channel, perform local account and legacy profile cleanup, then launch the Windows 11 upgrade.
3. Verify the operating system and domain, install the workstation application updater, and record the result.

Completed steps can be skipped. Scheduled tasks resume the workflow at administrator logon, and logs and summaries record phase outcomes.

## Before running

Review the script in an isolated Windows lab. It changes DNS and domain membership, can disable the local administrator and delete a profile, and can reboot or upgrade Windows. Use elevated Windows PowerShell 5.1. Replace the example domain and DNS values and review the other environment settings. Approved Windows upgrade media and the environment-specific application installer must be supplied separately. Keep operational logs and credentials outside this repository. The public edition was syntax-checked; its full migration workflow has not been exercised.
