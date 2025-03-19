using module ..\Source\FileGenerator\FileGeneratorConfig.psm1
using module ..\Source\FileGenerator\FileGenerator.psm1

$config = [FileGeneratorConfig]::new(
    "C:\Files",  # BasePath
    2,               # MaxDepth
    1,               # FileSizeMB
    5,               # Amount
    $false,          # RemoveLast10Files
    $false,          # Quiet
    "MD5",           # HashingAlgorithm
    "Files"          # FolderName
)

$jobs = @()
$moduleDir = "$PSScriptRoot\..\Source\FileGenerator"

foreach ($depth in 1..$config.MaxDepth) {
    $jobs += Start-Job -ScriptBlock {
        param($depth, $configJson, $moduleDir)
        
        $helperScript = Join-Path $moduleDir "ImportClasses.ps1"
        . $helperScript
        
        $config = [FileGeneratorConfig]::new()
        $properties = $configJson | ConvertFrom-Json
        foreach ($property in $properties.PSObject.Properties) {
            $config.$($property.Name) = $property.Value
        }
        
        $generator = [FileGenerator]::new($config)
        $generator.GenerateFilesForDepth($depth)
    } -ArgumentList $depth, ($config | ConvertTo-Json -Depth 10), $moduleDir
}

$jobs | Wait-Job | Receive-Job
$jobs | Remove-Job -Force

Write-Host "File generation completed." -ForegroundColor Green
