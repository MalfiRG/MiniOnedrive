<#
.SYNOPSIS
    Module containing the DirectoryService class for creating directory trees.
.DESCRIPTION
    This module defines the DirectoryService class, which is responsible for creating
    nested directory structures.
#>

class DirectoryService {
    [string] CreateDeepDirectoryTree([string] $BasePath, [string] $FolderName, [int] $Depth) {
        $currentPath = $BasePath
        foreach ($i in 1..$Depth) {
            $currentPath = Join-Path -Path $currentPath -ChildPath "$FolderName$i"
            if (-not (Test-Path -Path $currentPath)) {
                New-Item -Path $currentPath -ItemType Directory | Out-Null
            }
        }

        return $currentPath
    }
}
