; Prune installer, built by tool\package.ps1 with Inno Setup 6.
; Installs for the current Windows user only: no administrator prompt.
; Pass /DAppVersion=x.y.z and /DRelease=<Flutter Release folder>.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef Release
  #define Release "..\apps\declutter\build\windows\x64\runner\Release"
#endif

[Setup]
; Never change AppId: Windows uses it to find Prune for upgrades and uninstall.
AppId={{6B3F2E7A-4C1D-4E8B-9A57-2D0C8F1E3B94}
AppName=Prune
AppVersion={#AppVersion}
AppVerName=Prune {#AppVersion}
AppPublisher=Prune
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\Prune
DefaultGroupName=Prune
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\dist
OutputBaseFilename=Prune-{#AppVersion}-Setup
UninstallDisplayIcon={app}\Prune.exe
SetupIconFile=..\apps\declutter\windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#Release}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\docs\USER_GUIDE.md"; DestDir: "{app}"; DestName: "Read me first.txt"; Flags: ignoreversion isreadme

[Icons]
Name: "{autoprograms}\Prune"; Filename: "{app}\Prune.exe"
Name: "{autodesktop}\Prune"; Filename: "{app}\Prune.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Prune.exe"; Description: "{cm:LaunchProgram,Prune}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; What Prune saved about phones on this laptop (prune.db, preview copies).
; Backups in "Prune Backups" in the user folder are left alone.
Type: filesandordirs; Name: "{localappdata}\Prune"
