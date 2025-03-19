Using module ./Utils.psm1


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