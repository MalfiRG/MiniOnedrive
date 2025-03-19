<#
.SYNOPSIS
    Module containing the FileGenerator class for generating files in directories.
.DESCRIPTION
    This module defines the FileGenerator class, which orchestrates the creation of
    directory structures and generation of random files.
.EXAMPLE
    Import-Module .\FileGeneratorConfig.psm1
    Import-Module .\FileGenerator.psm1
    
    $config = [FileGeneratorConfig]::new("C:\Temp", 3, 10, 5)
    $generator = [FileGenerator]::new($config)
    $generator.GenerateFilesParallel()
#>

using module .\DirectoryService.psm1
using module .\HashingService.psm1
using module .\FileGenerationService.psm1
using module .\FileGeneratorConfig.psm1

class FileGenerator {
    [FileGeneratorConfig] $Config
    [DirectoryService] $DirectoryService
    [HashingService] $HashingService
    [FileGenerationService] $FileGenerationService
    
    FileGenerator([FileGeneratorConfig] $config) {
        $this.Config = $config
        $this.DirectoryService = [DirectoryService]::new()
        $this.HashingService = [HashingService]::new($config.HashingAlgorithm)
        $this.FileGenerationService = [FileGenerationService]::new($this.HashingService, $config.Quiet)
    }
    
    [void] GenerateFilesForDepth([int] $depth) {
        $finalPath = $this.DirectoryService.CreateDeepDirectoryTree(
            $this.Config.BasePath, 
            $this.Config.FolderName, 
            $depth
        )
        
        $this.FileGenerationService.GenerateRandomFiles(
            $finalPath, 
            $this.Config.FileSizeMB, 
            $this.Config.Amount, 
            $this.Config.RemoveLast10Files
        )
    }
}