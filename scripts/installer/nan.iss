; NaN Windows installer (Inno Setup 6.x).
;
; Invoked by .github/workflows/desktop-release.yml on windows-latest:
;   ISCC.exe /DMyVersion=<version> /DAppSourceDir=<Release dir> /DOutputDir=<dist> /DAppIcon=<ico> scripts\installer\nan.iss
;
; Local reproduction (PowerShell, repository root):
;   choco install innosetup -y
;   & "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" `
;       /DMyVersion=0.1.0 `
;       "/DAppSourceDir=$PWD\app\build\windows\x64\runner\Release" `
;       "/DOutputDir=$PWD\dist" `
;       "/DAppIcon=$PWD\app\windows\runner\resources\app_icon.ico" `
;       scripts\installer\nan.iss
;
; Output: dist\NaN-<version>-windows-x64-setup.exe
;   - installs to Program Files\NaN
;   - Start menu shortcut, desktop shortcut, uninstall entry
;   - stable AppId: upgrades replace the same installation
;   - version comes from the repository VERSION file (passed by the workflow)
;
; The wizard is Simplified Chinese when the installed Inno Setup ships
; Languages\ChineseSimplified.isl (official since Inno Setup 6.5.0). The
; workflow checks for the file and passes /DWithChineseSimplified=1; on older
; Inno Setup versions the wizard safely falls back to English instead of
; downloading a third-party translation. This .iss file is intentionally
; ASCII-only because Inno Setup 6.2 and earlier read non-BOM files using the
; system ANSI code page.

#ifndef MyVersion
#define MyVersion "0.1.0"
#endif
#ifndef AppSourceDir
#define AppSourceDir "..\..\app\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
#define OutputDir "..\..\dist"
#endif
#ifndef AppIcon
#define AppIcon "..\..\app\windows\runner\resources\app_icon.ico"
#endif

#define MyAppName "NaN"
#define MyAppExeName "NaN.exe"

; Enabled by the workflow only when the compiler ships the official Simplified
; Chinese messages (Inno Setup 6.5+). Without it the wizard stays English.
#ifdef WithChineseSimplified
[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif

[Setup]
; AppId must never change after the first public release, or an upgrade would
; install a second copy.
AppId={{958D16AF-1244-4512-8EB2-1E69E7495FFA}
AppName={#MyAppName}
AppVersion={#MyVersion}
AppVerName={#MyAppName} {#MyVersion}
AppPublisher=NaN
AppPublisherURL=https://github.com/asdshuaishuai/NoNDesign
AppSupportURL=https://github.com/asdshuaishuai/NoNDesign/issues
AppUpdatesURL=https://github.com/asdshuaishuai/NoNDesign/releases
VersionInfoVersion={#MyVersion}
VersionInfoCompany=NaN
VersionInfoDescription={#MyAppName} Setup
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyVersion}

DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableWelcomePage=no

; Output location and file name (version comes from /DMyVersion).
OutputDir={#OutputDir}
OutputBaseFilename=NaN-{#MyVersion}-windows-x64-setup
SetupIconFile={#AppIcon}

UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}

Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes

WizardStyle=modern
PrivilegesRequired=admin
; 64-bit Windows only (Windows 10/11 x64, plus x64 emulation on Arm64).
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0
CloseApplications=yes
RestartApplications=no
AllowNoIcons=yes

[Files]
; Whole Flutter Release folder: NaN.exe, data\, plugin runtimes.
Source: "{#AppSourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; Start menu: launch + uninstall.
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
; Desktop shortcut.
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
