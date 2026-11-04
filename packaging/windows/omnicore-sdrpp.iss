; Windows x64 installer of OmniCore-SDR-SDRPlusPlus. Built by build_installer.ps1, which passes:
;   PackageDir  the folder made by package.sh (sdrpp.exe, DLLs, modules\, res\)
;   DriverDir   OmniCore Host's driver assistant (och-driver.exe, libwdi.dll, licenses\)
;   OutputDir, AppVersion
#ifndef PackageDir
  #error PackageDir must be provided by build_installer.ps1
#endif
#ifndef DriverDir
  #error DriverDir must be provided by build_installer.ps1
#endif
#ifndef OutputDir
  #define OutputDir "..\..\release"
#endif
#ifndef AppVersion
  #define AppVersion "1.3.2"
#endif

[Setup]
AppId={{6B0C4E7A-3D52-4F4B-9C1E-5A8F2D7B3E61}
AppName=OmniCore SDR++
AppVersion={#AppVersion}
AppVerName=OmniCore SDR++ {#AppVersion}
AppPublisher=OmniCoreSDR
AppPublisherURL=https://github.com/Liren66/OmniCore-SDR-SDRPlusPlus
AppSupportURL=https://github.com/Liren66/OmniCore-SDR-SDRPlusPlus/issues
AppUpdatesURL=https://github.com/Liren66/OmniCore-SDR-SDRPlusPlus/releases
AppComments=SDR++ with the OmniCore SDR source
DefaultDirName={autopf}\OmniCore-SDR-SDRPlusPlus
DefaultGroupName=OmniCore SDR++
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0
PrivilegesRequired=admin
OutputDir={#OutputDir}
OutputBaseFilename=OmniCore-SDR-SDRPlusPlus-{#AppVersion}-windows-x64-setup
SetupIconFile={#PackageDir}\res\icons\sdrpp.ico
UninstallDisplayIcon={app}\sdrpp.exe
LicenseFile={#PackageDir}\LICENSE.txt
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName=OmniCore SDR++

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "driver"; Description: "Install/check the libusbK driver for OmniCore SDR (USB 1A86:5537 only)"; Flags: checkedonce
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Modules of an older version that this one no longer ships
Type: filesandordirs; Name: "{app}\modules"

[Files]
Source: "{#PackageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#DriverDir}\*"; DestDir: "{app}\driver"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\OmniCore SDR++"; Filename: "{app}\sdrpp.exe"; WorkingDir: "{app}"; IconFilename: "{app}\res\icons\sdrpp.ico"
Name: "{group}\Install OmniCore SDR driver"; Filename: "{cmd}"; Parameters: "/K """"{app}\driver\och-driver.exe"" install"""; WorkingDir: "{app}\driver"
Name: "{group}\Uninstall OmniCore SDR++"; Filename: "{uninstallexe}"
Name: "{autodesktop}\OmniCore SDR++"; Filename: "{app}\sdrpp.exe"; WorkingDir: "{app}"; IconFilename: "{app}\res\icons\sdrpp.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\sdrpp.exe"; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,OmniCore SDR++}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
var
  DriverResult: Integer;
  DriverAttempted: Boolean;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    DriverAttempted := WizardIsTaskSelected('driver');
    if DriverAttempted then begin
      WizardForm.StatusLabel.Caption := 'Checking the OmniCore SDR USB driver...';
      if not Exec(ExpandConstant('{app}\driver\och-driver.exe'), 'install', ExpandConstant('{app}\driver'), SW_HIDE, ewWaitUntilTerminated, DriverResult) then
        DriverResult := 4;
      Log(Format('OmniCore SDR driver helper result: %d', [DriverResult]));
    end;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then begin
    if DriverAttempted and (DriverResult = 2) then
      WizardForm.FinishedLabel.Caption := 'OmniCore SDR++ is installed. No OmniCore SDR was connected: after connecting it, run "Install OmniCore SDR driver" from the Start Menu.'
    else if DriverAttempted and (DriverResult <> 0) then
      WizardForm.FinishedLabel.Caption := 'OmniCore SDR++ is installed, but the USB driver could not be confirmed. Run "Install OmniCore SDR driver" from the Start Menu.'
    else
      WizardForm.FinishedLabel.Caption := 'OmniCore SDR++ is installed. Select "OmniCore SDR" as the source and press play. Settings are stored in %APPDATA%\OmniCore-SDR-SDRPlusPlus.';
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  { The shared libusbK driver and the user's settings in %APPDATA% are intentionally kept. }
end;
