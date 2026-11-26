param(
    [ValidateSet('x64', 'x86')][string[]]$Architecture = @('x64', 'x86'),
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '0.1.0',
    [string]$Iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root 'output'
if (-not (Test-Path -LiteralPath $Iscc -PathType Leaf)) {
    throw 'Inno Setup 6 was not found. Provide the path to ISCC.exe with -Iscc.'
}

New-Item -ItemType Directory -Path $output -Force | Out-Null
foreach ($arch in $Architecture) {
    $publish = Join-Path $output "publish-$arch"
    dotnet publish (Join-Path $root 'src/SkyPaste/SkyPaste.csproj') -c Release -r "win-$arch" `
        --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
        -p:EnableCompressionInSingleFile=true "-p:Version=$Version" "-p:FileVersion=$Version" -o $publish
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed for $arch." }

    Compress-Archive -LiteralPath (Join-Path $publish 'SkyPaste.exe') `
        -DestinationPath (Join-Path $output "SkyPaste-$Version-windows-$arch-portable.zip") -Force
    & $Iscc "/DMyAppVersion=$Version" "/DMyAppArch=$arch" "/DMyPublishDir=$publish" (Join-Path $root 'installer/SkyPaste.iss')
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed for $arch." }
}
