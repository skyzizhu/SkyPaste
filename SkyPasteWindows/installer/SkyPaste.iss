; SkyPaste for Windows - Inno Setup installer script
; Build: iscc installer\SkyPaste.iss  (after dotnet publish to publish\)

#define MyAppName "SkyPaste"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "SkyPaste"
#define MyAppExeName "SkyPaste.exe"

[Setup]
AppId={{7E1F6C42-9A3B-4E52-9C1D-8F0A55B21A07}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Per-user install so no admin rights are needed (clipboard apps usually are per-user)
PrivilegesRequired=lowest
OutputDir=..\output
OutputBaseFilename=SkyPaste-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=..\src\SkyPaste\Assets\icon.ico

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "{cm:LaunchAtLoginTask}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\publish\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\publish\app.manifest"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; HKCU Run key for launch at login (mirrors LaunchAtLoginService)
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "SkyPaste"; ValueData: """{app}\{#MyAppExeName}"""; \
    Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; \
    Flags: nowait postinstall skipifsilent

[CustomMessages]
LaunchAtLoginTask=Launch SkyPaste when I sign in
LaunchAtLoginTask.chinesesimplified=登录 Windows 时自动启动 SkyPaste
