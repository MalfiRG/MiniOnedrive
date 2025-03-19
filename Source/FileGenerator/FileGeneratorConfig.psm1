<#
.SYNOPSIS
    Module containing the FileGeneratorConfig class for configuration settings.
.DESCRIPTION
    This module defines the FileGeneratorConfig class, which is responsible for storing
    configuration settings for file generation.
#>

class FileGeneratorConfig {
    [string] $BasePath
    [int] $MaxDepth
    [int] $FileSizeMB
    [int] $Amount
    [bool] $RemoveLast10Files
    [bool] $Quiet
    [string] $HashingAlgorithm
    [string] $FolderName
    
    FileGeneratorConfig(
        [string] $basePath = "C:\",
        [int] $maxDepth = 2,
        [int] $fileSizeMB = 64,
        [int] $amount = 3,
        [bool] $removeLast10Files = $false,
        [bool] $quiet = $false,
        [string] $hashingAlgorithm = "MD5",
        [string] $folderName = "Files"
    ) {
        $this.BasePath = $basePath
        $this.MaxDepth = $maxDepth
        $this.FileSizeMB = $fileSizeMB
        $this.Amount = $amount
        $this.RemoveLast10Files = $removeLast10Files
        $this.Quiet = $quiet
        $this.HashingAlgorithm = $hashingAlgorithm
        $this.FolderName = $folderName
    }

    FileGeneratorConfig() {
    }
}
