using namespace System.IO
using module .\Source\Core\FolderSynchronizer.psm1
using module .\Source\Core\Utils.psm1



param(
    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path -Path $_ })]
    [string]$SourceFolder = "C:\Files",

    [Parameter(Mandatory = $false)]
    [string]$ReplicaFolder = "C:\FilesReplica",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = (Join-Path -Path $PSScriptRoot -ChildPath "Logs\$($MyInvocation.MyCommand.Name).log")
)


try {
    $logger = [Logger]::new($LogPath)
    $logger.Log("Starting MiniOneDrive. Source folder: $SourceFolder, Replica folder: $ReplicaFolder, Log path: $LogPath", "INFO")

    $synchronizer = [FolderSynchronizer]::new($SourceFolder, $ReplicaFolder, $LogPath)
    $synchronizer.FullSync()
    $synchronizer.CleanupReplica()
    
    try {
        while ($true) { Start-Sleep -Seconds 1 }
    }
    finally {
        if ($synchronizer -and $synchronizer.Synchronizer -and $synchronizer.Synchronizer.CheckpointManager) {
            $synchronizer.Synchronizer.CheckpointManager.SaveCheckpoint()
        }
            
        switch ($synchronizer) {
            { $_ -and $_.EventSubscriptions } {
                foreach ($subscription in $_.EventSubscriptions) {
                    $logger.Log("Unregistering event: $($subscription.Name)", "INFO")
                    Unregister-Event -SubscriptionId $subscription.Id -Force -ErrorAction SilentlyContinue
                    $logger.Log("Event unregistered: $($subscription.Name)", "INFO")
                }
            }
            { $_ -and $_.Watcher } {
                $logger.Log("Disabling watcher", "INFO")
                $_.Watcher.EnableRaisingEvents = $false
                $_.Watcher.Dispose()
                $logger.Log("Watcher and subscriptions disposed", "INFO")
            }
            { $_ -and $_.DebounceTimer } {
                $logger.Log("Stopping debounce timer", "INFO")
                $_.DebounceTimer.Stop()
                $_.DebounceTimer.Dispose()
                $logger.Log("Debounce timer disposed", "INFO")
            }
        }
    } 
}
catch {
    $logger.Log("Critical error in main synchronization process: $($_.Exception.Message)", "CRITICAL")
    $logger.Log("$($_ | Format-List -Force | Out-String)", "DEBUG")
    throw
}