$ErrorActionPreference = 'Stop'
$portsRoot = Split-Path -Parent $PSScriptRoot
$cargoCommand = Get-Command cargo -ErrorAction SilentlyContinue
$cargoExe = if ($cargoCommand) { $cargoCommand.Source } else { Join-Path $env:USERPROFILE '.cargo/bin/cargo.exe' }
Push-Location $portsRoot
try {
    dotnet publish windows/RainGlass.Controls/RainGlass.Controls.csproj -c Release -r win-x64 --self-contained true -o target/release/ui
    if ($LASTEXITCODE -ne 0) { throw 'WPF publish failed' }
    & $cargoExe build --locked --release -p rainglass-desktop
    if ($LASTEXITCODE -ne 0) { throw 'Rust build failed' }
    Compress-Archive -Path target/release/rainglass-desktop.exe,target/release/ui -DestinationPath RainGlass-Windows.zip -Force
    $compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
    if (Test-Path -LiteralPath $compiler) {
        & $compiler windows/RainGlass.iss
        if ($LASTEXITCODE -ne 0) { throw 'Installer build failed' }
    } else { Write-Host 'Portable ZIP built. Install Inno Setup 6 to also compile the installer.' }
    Write-Host "Portable release: $portsRoot/RainGlass-Windows.zip"
} finally { Pop-Location }
