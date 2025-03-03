using namespace System.IO
using module .\Utils.psm1


param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ })]
    [string]$SourceFolder,

    [Parameter(Mandatory = $true)]
    [string]$ReplicaFolder,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = (Join-Path -Path $PSScriptRoot -ChildPath "Logs\$($MyInvocation.MyCommand.Name).log")
)


class CheckpointManager {
    [string]$CheckpointPath
    [hashtable]$CheckpointData = @{}
    [Logger]$Logger

    CheckpointManager([string]$replicaPath, [Logger]$logger) {
        $this.Logger = $logger
        $this.CheckpointPath = Join-Path $replicaPath ".synchashes"
        $this.LoadCheckpoint()
    }

    [void] LoadCheckpoint() {
        try {
            if (Test-Path $this.CheckpointPath) {
                $this.Logger.Log("Loading checkpoint", "INFO")
                $content = Get-Content $this.CheckpointPath -Raw
                $this.CheckpointData = ConvertFrom-Json $content -AsHashtable
            }
            $this.Logger.Log("Checkpoint loaded", "INFO")
        } 
        catch {
            [Utilities]::HandleError("LoadCheckpoint", $this.CheckpointPath, $_, $this.Logger, $true)
        }
    }

    [void] SaveCheckpoint() {
        try {
            $this.Logger.Log("Saving checkpoint", "INFO")
            $this.CheckpointData | ConvertTo-Json -Depth 5 | Set-Content $this.CheckpointPath
            $this.Logger.Log("Checkpoint saved", "INFO")
        } 
        catch {
            [Utilities]::HandleError("SaveCheckpoint", $this.CheckpointPath, $_, $this.Logger, $true)
        }
    }

    [void] UpdateFileEntry([string]$relativePath, [string]$hash, [datetime]$lastModified, [string]$acl) {
        try {
            $this.Logger.Log("Updating entry: $relativePath", "INFO")
            $this.CheckpointData[$relativePath] = @{
                Hash         = $hash
                LastModified = $lastModified.ToString("o")
                ACL          = $acl
            }
            $this.Logger.Log("Entry updated: $relativePath", "INFO")
        }
        catch {
            [Utilities]::HandleError("UpdateFileEntry", $relativePath, $_, $this.Logger, $false)
        }
    }

    [void] RemoveFileEntry([string]$relativePath) {
        try {
            $this.Logger.Log("Removing entry: $relativePath", "INFO")
            $this.CheckpointData.Remove($relativePath)
        }
        catch {
            [Utilities]::HandleError("RemoveFileEntry", $relativePath, $_, $this.Logger, $false)
        }
    }
}

class FileValidator {
    [string]$SourceRoot
    [string]$ReplicaRoot
    [CheckpointManager]$CheckpointManager
    [Logger]$Logger
    [hashtable]$FileHashCache

    FileValidator([string]$sourceRoot, [string]$replicaRoot, [CheckpointManager]$checkpointManager, [Logger]$logger) {
        $this.SourceRoot = $sourceRoot
        $this.ReplicaRoot = $replicaRoot
        $this.CheckpointManager = $checkpointManager
        $this.Logger = $logger
        $this.FileHashCache = @{}
    }

    [bool] NeedsSync([FileInfo]$sourceFile) {
        try {
            $relativePath = [Path]::GetRelativePath($this.SourceRoot, $sourceFile.FullName)
            $replicaPath = Join-Path $this.ReplicaRoot $relativePath
            $checkpointEntry = $this.CheckpointManager.CheckpointData[$relativePath]
            $this.FileHashCache[$sourceFile.FullName] = $this.CheckpointManager.CheckpointData[$relativePath].Hash

            #phase 1: Check if checkpoint entry exists
            if (-not $checkpointEntry) {
                $this.FileHashCache[$sourceFile.FullName] = (Get-FileHash -Path $sourceFile.FullName -Algorithm "md5").Hash
                $this.Logger.Log("Needs sync because checkpoint entry does not exist: $relativePath", "INFO")
                return $true
            }
            
            # Phase 2: Check file existence

            if (-not (Test-Path $replicaPath)) {
                $this.FileHashCache[$sourceFile.FullName] = (Get-FileHash -Path $sourceFile.FullName -Algorithm "md5").Hash
                $this.Logger.Log("Needs sync because replica does not exist: $relativePath", "INFO")
                return $true 
            }

            # Phase 3: Check file size 
            $replicaFileInfo = Get-Item $replicaPath -ErrorAction SilentlyContinue
            if ($sourceFile.Length -ne $replicaFileInfo.Length) {
                $this.Logger.Log("Needs sync because file size mismatch: $relativePath", "INFO")
                return $true
            } 

            # Phase 4: Check ACL changes
            $sourceAcl = (Get-Acl $sourceFile.FullName).AccessToString
            $replicaAcl = (Get-Acl $replicaPath).AccessToString
            if ($sourceAcl -ne $replicaAcl) { 
                $this.Logger.Log("Needs sync because ACL mismatch: $relativePath", "INFO")
                return $true 
            }
            
            # Phase 5: Check timestamp 
            $sourceModified = $sourceFile.LastWriteTimeUtc
            if ([datetime]$checkpointEntry.LastModified -ne [datetime]$sourceModified) {
                $this.Logger.Log("Needs sync because timestamp mismatch: $relativePath", "INFO")
                # return $true
            }

            # Phase 6: Check content hash 
            $this.FileHashCache[$sourceFile.FullName] = (Get-FileHash -Path $sourceFile.FullName -Algorithm "md5").Hash
            if ($this.FileHashCache[$sourceFile.FullName] -ne $checkpointEntry.Hash) {
                $this.Logger.Log("Needs sync because hash mismatch: $relativePath", "INFO")
                return $true
            }

            $this.Logger.Log("No sync needed: $relativePath", "INFO")
            return $false
        }
        catch {
            [Utilities]::HandleError("NeedsSync", $sourceFile.FullName, $_, $this.Logger, $false)
            return $false
        }
    }

}

class FileSynchronizer {
    [string]$SourceRoot
    [string]$ReplicaRoot
    [Logger]$Logger
    [CheckpointManager]$CheckpointManager
    [FileValidator]$Validator

    FileSynchronizer(
        [string]$sourceRoot,
        [string]$replicaRoot,
        [Logger]$logger,
        [CheckpointManager]$checkpointManager,
        [FileValidator]$validator
    ) {
        $this.SourceRoot = $sourceRoot
        $this.ReplicaRoot = $replicaRoot
        $this.Logger = $logger
        $this.CheckpointManager = $checkpointManager
        $this.Validator = $validator
    }

    [void] SyncFile([string]$sourcePath) {
        $relativePath = [Path]::GetRelativePath($this.SourceRoot, $sourcePath)
        $replicaPath = Join-Path $this.ReplicaRoot $relativePath
        
        $syncOperation = {
            if (-not (Test-Path $sourcePath -ErrorAction Stop)) {
                throw "Source file not found: $sourcePath"
            }
    
            $fileInfo = Get-Item $sourcePath -ErrorAction Stop
            if (-not $this.Validator.NeedsSync($fileInfo)) { return }
    
            $directory = Split-Path $replicaPath -Parent
            if (-not (Test-Path $directory)) {
                New-Item -Path $directory -ItemType Directory -Force | Out-Null
                $this.Logger.Log("Created directory: $directory", "DIRCREATE")
            }
    
            Copy-Item $sourcePath $replicaPath -Force -ErrorAction Stop
            
            $hash = $this.Validator.FileHashCache[$sourcePath]
            $SourceACL = Get-Acl $sourcePath
            $replicaACL = Set-Acl -Path $replicaPath -AclObject $SourceACL -Passthru
            $this.CheckpointManager.UpdateFileEntry($relativePath, $hash, $fileInfo.LastWriteTimeUtc, $replicaACL.AccessToString)
            $this.CheckpointManager.SaveCheckpoint()
            $this.Logger.Log("Synced file: $relativePath", "FILEUPDATE")
        }
        
        try {
            [Utilities]::InvokeWithRetry($syncOperation, 3, 1, 2, "SyncFile: $relativePath", $this.Logger)
        }
        catch {
            [Utilities]::HandleError("SyncFile", $relativePath, $_, $this.Logger, $false)
        }
    }

    [void] DeleteOrphan([string]$replicaPath) {
        $relativePath = [Path]::GetRelativePath($this.ReplicaRoot, $replicaPath)
        Remove-Item $replicaPath -Force
        $this.CheckpointManager.RemoveFileEntry($relativePath)
        $this.Logger.Log("Removed orphan: $relativePath", "FILEDELETE")
    }
}

class FolderSynchronizer {
    [FileSystemWatcher]$Watcher
    [System.Collections.Generic.List[System.Management.Automation.PSEventJob]]$EventSubscriptions
    [FileSynchronizer]$Synchronizer
    [System.Timers.Timer]$DebounceTimer = [System.Timers.Timer]::new(500)
    [System.Collections.Generic.List[string]]$PendingChanges = [System.Collections.Generic.List[string]]::new()
    [Logger]$Logger

    FolderSynchronizer(
        [string]$sourcePath,
        [string]$replicaPath,
        [string]$logPath
    ) {
        $this.logger = [Logger]::new($logPath)
        $checkpointManager = [CheckpointManager]::new($replicaPath, $this.logger)
        $validator = [FileValidator]::new($sourcePath, $replicaPath, $checkpointManager, $this.logger)
        $this.Synchronizer = [FileSynchronizer]::new(
            $sourcePath,
            $replicaPath,
            $this.logger,
            $checkpointManager,
            $validator
        )
        
        $this.InitializeWatcher($sourcePath)
        $this.SetupDebounceTimer()
    }

    [void] InitializeWatcher([string]$sourcePath) {
        $this.Watcher = [FileSystemWatcher]::new($sourcePath)
        $this.Watcher.IncludeSubdirectories = $true
        $this.Watcher.NotifyFilter = 
        [NotifyFilters]::LastWrite, 
        [NotifyFilters]::FileName, 
        [NotifyFilters]::Security

        $this.EventSubscriptions += Register-ObjectEvent -InputObject $this.Watcher -EventName Created -Action { 
            try {
                $Event.MessageData.Logger.Log("Attempting to sync: $($Event.SourceEventArgs.FullPath)", "FILECREATE")
                $Event.MessageData.AddChange($Event.SourceEventArgs.FullPath) 
            }
            catch {
                $Event.MessageData.Logger.Log("Error in Create event: handler: $($_.Exception.Message)", "ERROR")
            }
        } -MessageData $this

        $this.EventSubscriptions += Register-ObjectEvent -InputObject $this.Watcher -EventName Changed -Action { 
            try {
                $Event.MessageData.Logger.Log("Attempting to sync: $($Event.SourceEventArgs.FullPath)", "FILEUPDATE")
                $Event.MessageData.AddChange($Event.SourceEventArgs.FullPath) 
            }
            catch {
                $Event.MessageData.Logger.Log("Error in Change event: handler: $($_.Exception.Message)", "ERROR")
            }
        } -MessageData $this

        $this.EventSubscriptions += Register-ObjectEvent -InputObject $this.Watcher -EventName Deleted -Action { 
            try {
                $Event.MessageData.Logger.Log("Attempting to delete: $($Event.SourceEventArgs.FullPath)", "FILEDELETE")
                $Event.MessageData.ProcessDeletion($Event.SourceEventArgs.FullPath) 
            }
            catch {
                $Event.MessageData.Logger.Log("Error in Delete event: handler: $($_.Exception.Message)", "ERROR")
            }
        } -MessageData $this

        $this.EventSubscriptions += Register-ObjectEvent -InputObject $this.Watcher -EventName Renamed -Action { 
            try {
                $Event.MessageData.Logger.Log("Attempting to rename: $($Event.SourceEventArgs.OldFullPath) -> $($Event.SourceEventArgs.FullPath)", "FILERENAME")
                $Event.MessageData.ProcessRename($Event.SourceEventArgs) 
            }
            catch {
                $Event.MessageData.Logger.Log("Error in Rename event: handler: $($_.Exception.Message)", "ERROR")
            }
        } -MessageData $this


        $this.Watcher.EnableRaisingEvents = $true
    }

    [void] SetupDebounceTimer() {
        try {
            $this.DebounceTimer.AutoReset = $false
            $this.EventSubscriptions += Register-ObjectEvent -InputObject $this.DebounceTimer -EventName Elapsed -Action {
                $handler = $Event.MessageData
                $uniquePaths = $handler.PendingChanges | Sort-Object -Unique
                $handler.PendingChanges.Clear()
                foreach ($path in $uniquePaths) {
                    $handler.Synchronizer.SyncFile($path)
                }
                $handler.Synchronizer.CheckpointManager.SaveCheckpoint()
            } -MessageData $this
        }
        catch {
            [Utilities]::HandleError("SetupDebounceTimer", "Debounce timer", $_, $this.Logger, $true)
        }
    }

    [void] AddChange([string]$fullPath) {
        try {
            $this.Logger.Log("Adding to pending changes: $fullPath", "PENDING")
            $this.PendingChanges.Add($fullPath)
            $this.Logger.Log("Debouncing changes", "DEBOUNCE")
            $this.DebounceTimer.Stop()
            $this.DebounceTimer.Start()
        }
        catch {
            [Utilities]::HandleError("AddChange", $fullPath, $_, $this.Logger, $true)
        }
    }

    [void] ProcessDeletion([string]$fullPath) {
        try {
            $relativePath = [Path]::GetRelativePath($this.Synchronizer.SourceRoot, $fullPath)
            $replicaPath = Join-Path $this.Synchronizer.ReplicaRoot $relativePath
            $this.Logger.Log("Processing deletion: $relativePath", "FILEDELETE")
            $this.Synchronizer.DeleteOrphan($replicaPath)
        }
        catch {
            [Utilities]::HandleError("ProcessDeletion", $fullPath, $_, $this.Logger, $true)
        }
    }

    [void] ProcessRename([System.IO.RenamedEventArgs]$e) {
        try {
            $this.Logger.Log("Processing rename: $($e.OldFullPath) -> $($e.FullPath)", "FILERENAME")
            $this.ProcessDeletion($e.OldFullPath)
            $this.Logger.Log("Attempting to sync: $($e.FullPath)", "FILECREATE")
            $this.AddChange($e.FullPath)
        }
        catch {
            [Utilities]::HandleError("ProcessRename", $e.FullPath, $_, $this.Logger, $true)
        }
    }


    [void] FullSync() {
        try {
            Get-ChildItem -Path $this.Synchronizer.SourceRoot -Recurse -File | ForEach-Object {
                $this.Logger.Log("Attempting to sync: $($_.FullName)", "FILECREATE")
                $this.Synchronizer.SyncFile($_.FullName)
            }
            $this.Synchronizer.CheckpointManager.SaveCheckpoint()
        }
        catch {
            [Utilities]::HandleError("FullSync", $this.Synchronizer.SourceRoot, $_, $this.Logger, $true)
        }
    }

    [void] CleanupReplica() {
        try {
            Get-ChildItem -Path $this.Synchronizer.ReplicaRoot -Recurse -File | ForEach-Object {
                $relativePath = [Path]::GetRelativePath($this.Synchronizer.ReplicaRoot, $_.FullName)
                $sourcePath = Join-Path $this.Synchronizer.SourceRoot $relativePath
                if (-not (Test-Path $sourcePath) -and -not $sourcePath.EndsWith(".synchashes")) {
                    $this.Logger.Log("Orphan detected: $relativePath", "FILEDELETE")
                    $this.Synchronizer.DeleteOrphan($_.FullName)
                }
            }
        }
        catch {
            [Utilities]::HandleError("CleanupReplica", $this.Synchronizer.ReplicaRoot, $_, $this.Logger, $true)
        }
    }
}

$logger = [Logger]::new($LogPath)
$logger.Log("Starting MiniOneDrive", "INFO")

try {
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