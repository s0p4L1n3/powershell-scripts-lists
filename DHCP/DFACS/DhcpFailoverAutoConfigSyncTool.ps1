$configFileName=".\Config_AutoSync.xml"
$sleepTimeInMilliSecs=0
$sleepTimeValueInMin=0
$masterMode=$true

$bkmrkName="PSDhcpAutoSyncBookmark"


# Logs output to output screen and file $outputFileName.
# If color value is given output on screen is logged with the given color value.
function log([string]$outputString,[string]$color)
{
    if($color -ne "")
    {
        Write-Host $outputString -ForegroundColor $color  #To log output on screen.
    }
    else
    {
        Write-Host $outputString  #To log output on screen.
    }
    $outputString >> $script:outputFileName #To log output to file $outputFileName.
} 

# Help function.
function Help()
{
	Write-Host ""
    Write-Host "USAGE: PS C:\>.\DhcpFailoverAutoConfigSyncTool.ps1" -ForegroundColor "Cyan"
    Write-Host "Config_AutoSync.xml present in current working directory will be used for configuration parameters." -ForegroundColor "Cyan"
	Write-Host ""
    Write-Host "In Default Replication Mode" -ForegroundColor "Cyan"
    Write-Host "    - The tool will sync any scope change belonging to all failover relations on this server." -ForegroundColor "Cyan"
	Write-Host "    - No specific admin action is required. The tool takes care of auto sync of all scopes in all Failover relations" -ForegroundColor "Cyan"
	Write-Host ""
    Write-Host "In Selective Replication Mode" -ForegroundColor "Cyan"
    Write-Host "    - The tool takes care of auto sync of ONLY the Failover relations mentioned in config file." -ForegroundColor "Cyan"
	Write-Host "    - Admin should add entries under <FailoverRelationships>. More details are provided in Config_AutoSync.xml" -ForegroundColor "Cyan"	
	Write-Host ""
    Write-Host "WARNING: When the tool is running, it will not pick" -ForegroundColor "Yellow"
	Write-Host "         1. Any change done in Config_AutoSync.xml. [Applicable for both Default Replication Mode and Selective Replication Mode]" -ForegroundColor "Yellow"	
    Write-Host "         2. Any new Failover relationship is created. [Applicable only in Selective Replication Mode]" -ForegroundColor "Yellow"	
    Write-Host "         SOLUTION: Stop the tool (By hitting Ctrl+C) and re-run the tool!" -ForegroundColor "Yellow"
}

# Closes tool gracefully clearing all registry keys, values.
# Assumes sever will be in sync when tool starts again.
function CloseTool()
{
    log "Tool is exiting." "Cyan"
    log "Deleting registry key maintained by the tool."
    
	try
    {
        Remove-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DHCPServer\Parameters\DHCPAutoSync" -ea stop
    }
    catch
    {
    }
	
    log "Shutting down completed successfully."
    exit
}

# Parse input configuration xml file.
function ParseInputXml()
{
    try
    {
        $inputXmlNode=[xml](Get-Content $Script:configFileName)
        $documentNode=$inputXmlNode.PSDhcpAutoSync
        if($documentNode -ne $null)
        {
            $logFileNameValue=$documentNode.LogFileName
            if($logFileNameValue -ne $null)
            {
                $script:outputFileName=$logFileNameValue
                try
                {
                    "$(Get-Date)" >> $script:outputFileName
                }
                catch
                {
                    Write-Host "WARNING: Unable to write to log file $script:outputFileName" -ForegroundColor "Yellow"
                    Write-host "WARNING: Writing to default log file .\DhcpAutoSyncLogfile.txt" -ForegroundColor "Yellow"
                    $script:outputFileName=".\DhcpAutoSyncLogfile.txt"
                    "$(Get-Date)" >> $script:outputFileName
                }
            }
            else
            {
				log "ERROR: <LogFileName> node is missing in Config_AutoSync.xml" "Red"
				CloseTool
            }
            $script:sleepTimeValueInMin=$documentNode.PeriodicRetryInterval
            if($sleepTimeValueInMin -ne $null)
            {
                $script:sleepTimeInMilliSecs=([int]$script:sleepTimeValueInMin)*(60*1000)
            }
            else
            {
                log "ERROR: <PeriodicRetryInterval> node is missing in Config_AutoSync.xml" "Red"
				CloseTool
            }
            $relationNode=$documentNode.FailoverRelationships
            $script:includeRelations=$relationNode.Include.Relation
            $script:excludeRelations=$relationNode.Exclude.Relation
        }
        else
        {
            Write-Host "ERROR: Unable to read configuration file Config_AutoSync.xml" -ForegroundColor "Red"
            CloseTool
        }
    }
    catch
    {
        Write-Host "ERROR: Unable to read configuration file Config_AutoSync.xml" -ForegroundColor "Red"
        CloseTool
    }
}

# Checks input relation and makes sure if script is running on other side 
# it is not syncing scopes for this relation.
function CheckRelation($relationName)
{
    try
    {
        $failoverRelation=Get-DhcpServerv4Failover -Name $relationName -ea Stop
        $remoteServerName=$failoverRelation.PartnerServer
        $baseKey=[Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine',$remoteServerName)
        try
        {
            $dhcpAutoSyncKey=$baseKey.OpenSubKey("SYSTEM\\CurrentControlSet\\Services\\DHCPServer\\Parameters\\DHCPAutoSync")
            if(($dhcpAutoSyncKey.GetValueNames() -contains $relationName) -or 
			   ($dhcpAutoSyncKey.GetValue("MasterMode") -eq "True"))
            {
              log "DhcpFailoverAutoConfigSyncTool is already running on partner server for Failover relation $relationName." "Red"
              log "If the tool is not running on the partner server or some other error has occured, then please restart " "Red"
			  log "the tool on server $remoteServerName or exclude Failover relation $relationName from current context." "Red"
			  log "ERROR: Conflict Detected! Aborting script..." "Red"
              exit
            }
            log "Adding relation $relationName to list of relations which will be automatically synced."
            [System.Array]$script:allRelations += $relationName
        }
        catch # Tool not running on other side.
        {
            log "Adding relation $relationName to list of relations which will be automatically synced."
            [System.Array]$script:allRelations += $relationName
        }
    } # Relation is down or doesn't exist.
    catch
    {
        log "WARNING: Partner server for relation $relationName not accessible." "Yellow"
        log "Adding relation $relationName to list of relations which will be automatically synced."
        [System.Array]$script:allRelations += $relationName
    }
}

# Checks every relation considered for sync and makes sure script 
# is not running on other side/server also with this relation initially.
function CheckAllRelations()
{
    if($script:includeRelations -eq $null) # If no relation is given to be included than including all as default case.
    {
        $script:includeRelations=(Get-DhcpServerv4Failover).Name
        $Script:masterMode = $Script:masterMode -and $true
    }
    else
    {
        $Script:masterMode = $Script:masterMode -and $false
    }
    if($script:excludeRelations -eq $null)
    {
        $Script:masterMode = $Script:masterMode -and $true
    }
    else
    {
        $script:includeRelations= @($script:includeRelations| Where-Object {$script:excludeRelations -notcontains $_})
        $Script:masterMode = $Script:masterMode -and $false
    }
    foreach($relationName in $script:includeRelations)
    {
        CheckRelation $relationName
    }
    if($Script:masterMode)
    {
        log "Running script in Default Replication Mode." "Cyan"
        log "All scopes belonging to any failover relation (including the newly added relations) will be synced automatically."
    }
    else
    {
        log "Running script in Selective Replication Mode." "Cyan"
        if($script:allRelations -eq $null)
        {
            log "WARNING: No failover relation found to sync." "Yellow"
            log "Cleaning all and exiting."
            CloseTool
        }
        log "Scope belonging to following failover relations will be automatically synced:"
        foreach($relationName in $script:allRelations)
        {
            log "$relationName"
        }
    }
}

# Initializes all variables and all 
# relations which this script will handle.
function Initialize()
{
    if($Script:args.count -gt 0)
    {
		Help
        exit
    }

    if(Test-Path $Script:configFileName)
    {
        Write-Host "Parsing Xml Configuration file."
        ParseInputXml
        Write-Host "Configuration file parsed."
    }
    else
    {
        Write-Host "Configuration file $Script:configFileName not found."
		Help
        exit
    }
    CheckAllRelations
	
	log "Initialization Complete." "Cyan"
}


# Initializing...
Initialize

# Tries to sync given scope $scopeName with recordId $recordId.
# If it fails due to network problem then it automatically tries again
# later else logs error with red color and scope has to be synced manually.
# In selective if scope belongs to relation not under consideration 
# than changes are ignored.
function TrySync([string]$scopeName,[int64]$recordId)
{
    try
    {
        $output=Get-DhcpServerv4Failover -ScopeId $scopeName -ea stop
        if($script:masterMode -or ($script:allRelations -contains $($output.Name)))
        {
            try
            {
                $output=Invoke-DhcpServerv4FailoverReplication -ScopeId $scopeName -Force -ea stop
                log "Scope $output synced." "Green"
            }
            catch
            {
                if($Error[0].FullyQualifiedErrorId -match $script:networkDownError)
                {
                    log ""
                    log "ERROR: $($Error[0])" "Red"
                    log "--------------------------------------------------------------------------------------------------"
                    log "Unable to sync scope $scopeName because of some network problem. Will automatically try again" "Red"
                    log "after $script:sleepTimeValueInMin Minutes." "Red"
                    log "--------------------------------------------------------------------------------------------------"
                    try
                    {
                        $script:pendingScopesTable.Add($scopeName,"")
                    }
                    catch
                    {
                    }
                }
                else
                {
                    log ""
                    log "ERROR: $($Error[0])" "Red"
                    log "ErrorId: $($Error[0].FullyQualifiedErrorId)" "Red"
                    log "ErrorDetails: $($Error[0].ErrorDetails)" "Red"
                    log "ErrorCategory: $($Error[0].CategoryInfo)" "Red"
                    log "--------------------------------------------------------------------------------------------------"
                    log "Scope $scopeName not synced. Please sync it manually." "Red"
                    log "--------------------------------------------------------------------------------------------------"
                }
            }
        }
        else
        {
            #log "WARNING: Scope $scopeName belongs to relation $($output.Name) which doesn't belong to set of relations being automatically synced." "Yellow"
			#log "Not syncing changes made to scope $scopeName." "Yellow"
        }
    }
    catch
    {
        # Scope doesn't belong to any relation please create a failover relation for it to ensure safety.
        log "WARNING: Scope $scopeName doesn't belong to any failover relation and the changes will " "Yellow"
		log "not be synchronized.Please create a failover relation for it to ensure safety." "Yellow"
    }
    $script:bkmrk=$recordId
}




# C# code for event subscription.
# Wait is done till new event is registered or timeout time $sleepTimeValueInMin is reached.

$EventSubscriptionCode = @"
using System;
using System.Threading;
using System.Diagnostics.Eventing.Reader;

namespace PSDHCPAutoSyncEventSubscription
{
    public class EventSubscription
    {
        public AutoResetEvent newEventRegistered = new AutoResetEvent(false);
        public bool ctrlCPressed=false;
        public void SubscribeEvents()
        {
            EventLogQuery subscriptionQuery = 
				new EventLogQuery("Microsoft-Windows-Dhcp-Server/Operational", PathType.LogName, "*[System[EventID>=0]]");
            EventLogWatcher scopeRelationChangeEventWatcher = new EventLogWatcher(subscriptionQuery);
            scopeRelationChangeEventWatcher.EventRecordWritten +=
            new EventHandler<EventRecordWrittenEventArgs>(ScopeRelationChangeEventRead);
            scopeRelationChangeEventWatcher.Enabled = true;

            Console.TreatControlCAsInput = false;
            Console.CancelKeyPress += new ConsoleCancelEventHandler(CtrlCHandler);
        }
        public void ScopeRelationChangeEventRead(object obj, EventRecordWrittenEventArgs arg)
        {
            newEventRegistered.Set();
        }
        public void CtrlCHandler(object sender, ConsoleCancelEventArgs args)
        {
            ctrlCPressed=true;
            args.Cancel=true;
            newEventRegistered.Set();
        }
    }
}

"@

# Adding C# code to PowerShell script and creating new object of this type.
Add-Type -TypeDefinition $EventSubscriptionCode -Language CSharp
$eventSubscriber = New-Object PSDHCPAutoSyncEventSubscription.EventSubscription

# Extracts current bookmark from registry. If it is not available than 
# assumes servers are already in sync and starts sync process from current time.
try
{
    $output=New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DHCPServer\Parameters\DHCPAutoSync" -ea stop
}
catch
{
    # Removing these warnings since they are irrelevant when integrated with schtask
    #log "WARNING: Encountered error while creating new Registry key." "Yellow"
    #log "         Possibly the tool was not closed properly during last execution." "Yellow"
	#log "         ERROR Value: $($Error[0])" "Yellow"
    
    # Cleaning all values in key except bookmark.
    try
    {
        log "Cleaning all previous values in key except bookmark."
        $baseKey=Get-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DHCPServer\Parameters\DHCPAutoSync" -ea stop
        $keyValueNames=$baseKey.GetValueNames()
        foreach($keyValueName in $keyValueNames)
        {
            if($keyValueName -ne $bkmrkName)
            {
                Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DHCPServer\Parameters\DHCPAutoSync" -Name $keyValueName -ea stop 
            }
        }
    }
    catch
    {
        log "WARNING: Unable to clean registry." "Yellow"
    }
}
if($masterMode)
{
    try
    {
        $output=New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DHCPServer\Parameters\DHCPAutoSync" -Name "MasterMode" -PropertyType String -Value "True" -ea stop
    }
    catch
    {
        # Removing these warnings since they are irrelevant when integrated with schtask
		#log "WARNING: Encountered error while creating new Registry value string MasterMode." "Yellow"
		#log "         ERROR Value: $($Error[0])" "Yellow"
    }
}
else
{
    foreach($relationName in $script:allRelations)
    {
        try
        {
            $output=New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DHCPServer\Parameters\DHCPAutoSync" -Name $relationName -PropertyType String -Value "" -ea stop
        }
        catch
        {
            # Removing these warnings since they are irrelevant when integrated with schtask
			#log "WARNING: Encountered error while creating new Registry value string $relationName." "Yellow"
			#log "         ERROR Value: $($Error[0])" "Yellow"
        }
    }
}
try
{
    $output=New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DHCPServer\Parameters\DHCPAutoSync" -Name "$bkmrkName" -PropertyType String -Value "" -ea stop
}
catch
{
    # Removing these warnings since they are irrelevant when integrated with schtask
	#log "WARNING: Encountered error while creating new Registry value string for bookmark." "Yellow"
	#log "         ERROR Value: $($Error[0])" "Yellow"
}

try
{
    [PSCustomObject]$bkmrk=Get-ItemProperty  -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DHCPServer\Parameters\DHCPAutoSync" -Name "$bkmrkName" -ea stop
    $bkmrk=$bkmrk.$bkmrkName
    if(($bkmrk -eq "") -or ($bkmrk -eq $null))
    {
        try
        {
            $bkmrk=Get-WinEvent -LogName "Microsoft-Windows-Dhcp-Server/Operational" -MaxEvents 1
            $bkmrk=$bkmrk.RecordId
        }
        catch # No events in event log.
        {
            [int64]$bkmrk=-1
        }
    }
    else
    {    
        $bkmrk=[int64]$bkmrk
    }
}
catch #Registry corrupted
{
    try
    {
        $bkmrk=Get-WinEvent -LogName "Microsoft-Windows-Dhcp-Server/Operational" -MaxEvents 1
        $bkmrk=$bkmrk.RecordId
    }
    catch # No events in event log.
    {
        [int64]$bkmrk=-1
    }
}

# Bool which is set if record id overflows max int64 value.
$recordIdOverflow=$false

# Network errors contain this string.
$networkDownError="WIN32 17"

# Scopes which do not get synced due to network errors
# are added to this hashtable. They are synced again whenever do while 
# loop starts again.
$pendingScopesTable=@{}

# Is set true if wait returns without timeout i.e. if new event occurs before $sleepTimeInMilliSecs.
$wait=$true

# Main code starts here...

# Suscribing to events.
$eventSubscriber.SubscribeEvents()

$sw = New-Object System.Diagnostics.StopWatch
$sw.Start()

# Syncs all modified scopes whenever a scope modification event is 
# registered or timeout time $sleepTimeValueInMin is reached.
do
{
    
    if($sw.Elapsed.TotalMinutes -gt $sleepTimeValueInMin)
    {
         try
         {            
            if($Script:masterMode)
            {
                $script:includeRelations=(Get-DhcpServerv4Failover).Name                
            }

            log "Periodic Sync TimeOut Happened:"
            foreach($relationName in $script:includeRelations)
            {
                if($relationName -ne $null)
                {
                    log "Syncing Relation:$relationName"
                    Invoke-DhcpServerv4FailoverReplication -Name $relationName  -Force 
                }
            }
        log "Sync process complete at $(Get-Date)."
        log "==================================================================================================" "Green"
         }
        catch
		{
			if($Error[0].FullyQualifiedErrorId -match $networkDownError)
			{
				log ""
				log "Error: $($Error[0])" "Red"
				log "--------------------------------------------------------------------------------------------------"
				log "Unable to sync scope $scopeName because of some network problem. Will automatically try again "
				log "after $script:sleepTimeValueInMin Minutes."
				log "--------------------------------------------------------------------------------------------------"
			}
			else
			{
				log ""
				log "Error: $($Error[0])" "Red"
				log "ErrorId: $($Error[0].FullyQualifiedErrorId)" "Red"
				log "ErrorDetails: $($Error[0].ErrorDetails)" "Red"
				log "ErrorCategory: $($Error[0].CategoryInfo)" "Red"
				log "--------------------------------------------------------------------------------------------------"
				log "Scope $scopeNameCurr not synced.Please sync it manually." "Red"
				log "If it does not belong to any relation please create a failover relation for it to ensure safety."
				log "--------------------------------------------------------------------------------------------------"                        
			}                
		}                     
        finally
        {
           $sw.Restart();
        }
    }
    else
    {    
        $scopeNamePrev=$null
        $scopeNameCurr=$null
        $syncedScopesTable=@{}

        # Checking RecordId has not overflown.
        if($bkmrk -eq [System.Int64]::maxvalue)
        {
            $recordIdOverflow=$true
        }
        if($pendingScopesTable.Count -ne 0)
        {
            log ""
            log "Syncing scopes which were not synced earlier due to network problem."
            foreach($scopeName in $pendingScopesTable.Keys)
            {
                try
                {
                    $output=Invoke-DhcpServerv4FailoverReplication -ScopeId $scopeName -Force -ea stop
                    log "Scope $output synced." "Green"
                    try
                    {
                        $syncedScopesTable.Add($scopeName,"")
                    }
                    catch
                    {
                    }
                }
                catch
                {
                    if($Error[0].FullyQualifiedErrorId -match $networkDownError)
                    {
                        log ""
                        log "Error: $($Error[0])" "Red"
                        log "--------------------------------------------------------------------------------------------------"
                        log "Unable to sync scope $scopeName because of some network problem. Will automatically try again "
                        log "after $script:sleepTimeValueInMin Minutes."
                        log "--------------------------------------------------------------------------------------------------"
                    }
                    else
                    {
                        log ""
                        log "Error: $($Error[0])" "Red"
                        log "ErrorId: $($Error[0].FullyQualifiedErrorId)" "Red"
                        log "ErrorDetails: $($Error[0].ErrorDetails)" "Red"
                        log "ErrorCategory: $($Error[0].CategoryInfo)" "Red"
                        log "--------------------------------------------------------------------------------------------------"
                        log "Scope $scopeNameCurr not synced.Please sync it manually." "Red"
                        log "If it does not belong to any relation please create a failover relation for it to ensure safety."
                        log "--------------------------------------------------------------------------------------------------"
                        try
                        {
                            $syncedScopesTable.Add($scopeName,"")
                        }
                        catch
                        {
                        }
                    }
                }
            }
            foreach($scopeName in $syncedScopesTable.Keys)
            {
                $pendingScopesTable.Remove($scopeName)
            }
        }

        try
        {
            $eventarray=Get-WinEvent -LogName "Microsoft-Windows-Dhcp-Server/Operational" -FilterXPath "*[System[(EventRecordID > $bkmrk)]]" -Oldest -ea stop
        }
        catch
        {
            $eventarray=$null
        }
        foreach ($event in $eventarray)
        {
            $eventXmlNode = [xml] $event.ToXml()
            $eventScopeNameNode = $eventXmlNode.Event.EventData.Data | where { ($_.Name -eq "IP_ScopeName") -or ($_.Name -eq "IP_Name") }
            $eventScopeNameValue=$eventScopeNameNode.'#text'
            if($eventScopeNameValue -ne $null)
            {
                $eventScopeNameValueSplit=$eventScopeNameValue.Split("[").Split("]")
                $eventScopeNameValueSplit = $eventScopeNameValueSplit | where { $_ -ne ""}
                $scopeNameCurr=$eventScopeNameValueSplit[0]
                if(($scopeNamePrev -eq $null) -or ($scopeNamePrev -eq $scopeNameCurr))
                {
                    $scopeNamePrev=$scopeNameCurr
                }
                else
                {
                    TrySync "$scopeNamePrev" $($event.RecordId - 1 )
                    $scopeNamePrev=$scopeNameCurr
                }
            }
        }
        if($scopeNameCurr -ne $null)
        {
            TrySync "$scopeNameCurr" $event.RecordId
        }
        if($eventarray -ne $null)
        {
            $bkmrk=$event.RecordId
        }

        if($pendingScopesTable.Count -eq 0)
        {
            Set-ItemProperty -path "HKLM:\SYSTEM\CurrentControlSet\Services\DHCPServer\Parameters\DHCPAutoSync" -Name "$bkmrkName" -Value "$bkmrk"
        }
    
        # Reseting signal for new events as all new events will be considered after this.
        $reset=$eventSubscriber.newEventRegistered.Reset()

        # Checks if log contains entry after bookmark than start sync process again without logging.
        # It is possible if new events are logged while earlier events were getting processed.
        try
        {
            $eventarray=Get-WinEvent -LogName "Microsoft-Windows-Dhcp-Server/Operational" -FilterXPath "*[System[(EventRecordID > $bkmrk)]]" -Oldest -ea stop
        }
        catch
        {
            if(($eventarray -ne $null) -or 
		       ($pendingScopesTable.Count -ne 0) -or 
		       ($syncedScopesTable.Count -ne 0) -or ($wait)) # Check if anything happend in this loop.
            {
                if($pendingScopesTable.Count -eq 0)
                {
                    log "Sync process complete at $(Get-Date)."
                    log "Will automatically sync again when new configuration changes are made."
                    log "==================================================================================================" "Green"
                }
                else
                {
                    log "Sync process complete at $(Get-Date)."
                    log "Will automatically sync again when new configuration changes are made or after $script:sleepTimeValueInMin Minutes."
                    log "=================================================================================================="
                }
            }
            if($eventSubscriber.ctrlCPressed -eq $true)
            {
                CloseTool
            }
            $wait=$eventSubscriber.newEventRegistered.WaitOne($sleepTimeInMilliSecs, $true)
            if($eventSubscriber.ctrlCPressed -eq $true)
            {
                CloseTool
            }
        }
    }
}
while(-not $recordIdOverflow)

# Record id has overflown. Stopping tool with warning.

log "Record Id in the events log has overflown." "Red"
log "Please clear log Microsoft-Windows-Dhcp-Server/Operational and restart tool." "Red"
CloseTool
