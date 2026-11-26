; SkyPaste for Windows - Inno Setup installer script
; Build: scripts\Build-Windows.ps1, or ISCC after publishing to publish\.

#define MyAppName "SkyPaste"
; Version comes from CI via /DMyAppVersion=<tag>; local default below.
#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#define MyAppPublisher "SkyPaste"
#define MyAppExeName "SkyPaste.exe"
#ifndef MyAppArch
  #define MyAppArch "x64"
#endif
#ifndef MyPublishDir
  #define MyPublishDir "..\publish"
#endif

[Setup]
AppId={{7E1F6C42-9A3B-4E52-9C1D-8F0A55B21A07}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
MinVersion=10.0.19041
#if MyAppArch == "x64"
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#elif MyAppArch == "x86"
ArchitecturesAllowed=x86compatible
#else
  #error Unsupported architecture
#endif
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Per-user install so no admin rights are needed (clipboard apps usually are per-user)
PrivilegesRequired=lowest
OutputDir=..\output
OutputBaseFilename=SkyPaste-Setup-{#MyAppVersion}-{#MyAppArch}
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
Name: "autostart"; Description: "Launch SkyPaste at sign-in / 登录时自动启动"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#MyPublishDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; HKCU Run key for launch at login (mirrors LaunchAtLoginService)
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "SkyPaste"; ValueData: """{app}\{#MyAppExeName}"""; \
    Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\{#MyAppExeName}"; Parameters: "--show-panel"; Description: "{cm:LaunchProgram,{#MyAppName}}"; \
    Flags: nowait postinstall skipifsilent

