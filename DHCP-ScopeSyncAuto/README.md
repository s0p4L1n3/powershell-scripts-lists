If you setup Windows DHCP in Failover mode with a second Windows Server, you should be aware that the scopes change you made on the primary server are not automatically replicated.
That's why you will need to setup a way to automate this.

## Prerequisites

- gMSA KDS Root Key active
- 2 Windows DHCP server in failover mode

## How to

- Create a script Sync-DhcpReservations.ps1 to the desired path on the server e.g: C:\Scripts\
```PowerShell
$ErrorActionPreference="Continue"
Start-Transcript -Path 'C:\Logs\DHCP-Failover_logs.txt' -Append

Import-Module DhcpServer
Invoke-DhcpServerv4FailoverReplication -ComputerName srvad1.domain.lan -Force

Stop-Transcript
```

- Create the gMSA that will be used to run the scheduled task on the DHCP Server
```PowerShell
New-ADServiceAccount -Name DC_gMSA -DNSHostName DC_gMSA.domain.lan `
-PrincipalsAllowedToRetrieveManagedPassword "Domain Controllers"
```

> In my case, the DHCP roles are installed along with the Active Directory role.
> Change `Domain Controller` to the desired groups containing both DHCP server object in the case they are not installed on the Active Directory windows server

- Create the scheduled task throught Powershell as you can't create Scheduled task by specifiying a gMSA account through the GUI.

```PowerShell
$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-File "C:\Scripts\Sync-DhcpReservations.ps1"'
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 10)
$Principal = New-ScheduledTaskPrincipal -UserId 'DOMAIN\DC_gMSA$' -LogonType Password -RunLevel Highest
$Settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -Compatibility Win8
Register-ScheduledTask -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -TaskName 'Replicate DHCP Scope Options' -TaskPath \
```

> `-Compatibility Win8` tells to Run the scheduled task for Windows Server 2022
> 
> Don't add argument `-RepetitionDuration`, it will automatically recognized the task to run indefinitely


For server configuration, there is no way to replicate it with the script. As a workaround, you can use PowerShell cmdlet to add it (**run the cmdlet from the failover server**)

```PowerShell
Get-DhcpServerv4Policy -computername srvad1.domain.lan | add-dhcpserverv4policy  
```
