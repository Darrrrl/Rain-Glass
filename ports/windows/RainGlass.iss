#define AppName "RainGlass"
#define AppVersion "0.1.0"
#define AppExe "rainglass-desktop.exe"

[Setup]
AppId={{61D45072-E917-4F92-91FA-7B23F93313EB}
AppName={#AppName}
AppVersion={#AppVersion}
DefaultDirName={autopf}\RainGlass
DefaultGroupName=RainGlass
OutputDir=dist
OutputBaseFilename=RainGlass-Windows-Setup
Compression=lzma
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#AppExe}

[Files]
Source: "..\target\release\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\target\release\ui\*"; DestDir: "{app}\ui"; Flags: ignoreversion recursesubdirs createallsubdirs

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "RainGlass"; Flags: uninsdeletevalue

[Icons]
Name: "{group}\RainGlass"; Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall RainGlass"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch RainGlass"; Flags: nowait postinstall skipifsilent
