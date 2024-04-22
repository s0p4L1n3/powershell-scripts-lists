$scriptName="DhcpFailoverAutoConfigSyncTool.ps1"
$programArguments = Join-Path $pwd $scriptName
$taskName="Microsoft\Windows\DHCPServer\DhcpFailoverAutoConfigSyncTool"
$taskRun="PowerShell.exe -WindowStyle Hidden -Command `&{cd $pwd; $programArguments}"
SCHTASKS /Create /SC "ONSTART" /RL HIGHEST /DELAY 0001:00 /TN $taskName /TR $taskRun
