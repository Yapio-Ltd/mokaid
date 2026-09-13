; All paths and product metadata are supplied by release.py, never by end users.
#ifndef ProductName
  #error ProductName must be defined
#endif
[Setup]
AppId={#BundleId}
AppName={#ProductName}
AppVersion={#Version}
AppPublisher=Yapio Ltd
AppPublisherURL=https://mokaid.com
AppSupportURL=https://mokaid.com
AppUpdatesURL=https://mokaid.com/download
DefaultDirName={localappdata}\Programs\{#ProductName}
DefaultGroupName={#ProductName}
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile={#IconPath}
UninstallDisplayIcon={app}\Mokaid.exe
UninstallDisplayName={#ProductName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
CloseApplicationsFilter=*.exe
RestartApplications=no
AppMutex={#BundleId}
SignedUninstaller=yes
SignTool=azure
SignToolRetryCount=3
SignToolRetryDelay=5000
DisableProgramGroupPage=yes
LicenseFile={#LicensePath}

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#ProductName}"; Filename: "{app}\Mokaid.exe"
Name: "{autodesktop}\{#ProductName}"; Filename: "{app}\Mokaid.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Mokaid.exe"; Description: "Launch {#ProductName}"; Flags: nowait postinstall skipifsilent runasoriginaluser
