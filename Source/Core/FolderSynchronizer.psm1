Using namespace System.IO
Using module .\Utils.psm1
Using module .\FileValidator.psm1
Using module .\CheckpointManager.psm1
Using module .\FileSynchronizer.psm1


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