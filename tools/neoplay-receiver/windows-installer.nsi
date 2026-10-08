Unicode true
!include "MUI2.nsh"
!include "FileFunc.nsh"

!ifndef APP_DIR
  !error "Pass /DAPP_DIR=<full path to win-unpacked>"
!endif
!ifndef OUT_PATH
  !error "Pass /DOUT_PATH=<full path to NeoPlay-Setup-0.7.0.exe>"
!endif
!ifndef ICON_PATH
  !error "Pass /DICON_PATH=<full path to NeoPlay icon>"
!endif
!ifndef LICENSE_PATH
  !error "Pass /DLICENSE_PATH=<full path to LICENSE.md>"
!endif
!ifndef README_PATH
  !error "Pass /DREADME_PATH=<full path to README-WINDOWS.txt>"
!endif

Name "NeoPlay"
OutFile "${OUT_PATH}"
InstallDir "$LOCALAPPDATA\Programs\NeoPlay"
InstallDirRegKey HKCU "Software\NeoStation\NeoPlay" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
BrandingText "NeoPlay - NeoStation"
ShowInstDetails nevershow
ShowUninstDetails nevershow

VIProductVersion "0.7.0.0"
VIAddVersionKey "ProductName" "NeoPlay"
VIAddVersionKey "FileDescription" "NeoPlay 0.7.0 Windows installer"
VIAddVersionKey "CompanyName" "NeoStation"
VIAddVersionKey "LegalCopyright" "NeoPlay contributors - GPL-3.0-or-later"
VIAddVersionKey "FileVersion" "0.7.0.0"
VIAddVersionKey "ProductVersion" "0.7.0.0"

!define MUI_ICON "${ICON_PATH}"
!define MUI_UNICON "${ICON_PATH}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\NeoPlay.exe"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${LICENSE_PATH}"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

!define MUI_LANGDLL_REGISTRY_ROOT "HKCU"
!define MUI_LANGDLL_REGISTRY_KEY "Software\NeoStation\NeoPlay"
!define MUI_LANGDLL_REGISTRY_VALUENAME "InstallerLanguage"

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "French"
!insertmacro MUI_LANGUAGE "German"
!insertmacro MUI_LANGUAGE "Spanish"
!insertmacro MUI_LANGUAGE "Italian"
!insertmacro MUI_LANGUAGE "Portuguese"
!insertmacro MUI_LANGUAGE "Russian"
!insertmacro MUI_LANGUAGE "Indonesian"
!insertmacro MUI_LANGUAGE "Japanese"
!insertmacro MUI_LANGUAGE "Korean"
!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "TradChinese"

Function .onInit
  !insertmacro MUI_LANGDLL_DISPLAY
FunctionEnd

Section "NeoPlay" SEC_INSTALL
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "${APP_DIR}\*.*"
  File "/oname=LICENSE.md" "${LICENSE_PATH}"
  File "/oname=README-WINDOWS.txt" "${README_PATH}"

  CreateDirectory "$SMPROGRAMS\NeoPlay"
  CreateShortCut "$SMPROGRAMS\NeoPlay\NeoPlay.lnk" "$INSTDIR\NeoPlay.exe"
  CreateShortCut "$DESKTOP\NeoPlay.lnk" "$INSTDIR\NeoPlay.exe"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortCut "$SMPROGRAMS\NeoPlay\Uninstall NeoPlay.lnk" "$INSTDIR\Uninstall.exe"

  WriteRegStr HKCU "Software\NeoStation\NeoPlay" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoPlay" "DisplayName" "NeoPlay 0.7.0"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoPlay" "DisplayVersion" "0.7.0"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoPlay" "Publisher" "NeoStation"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoPlay" "DisplayIcon" "$INSTDIR\NeoPlay.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoPlay" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoPlay" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoPlay" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoPlay" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$DESKTOP\NeoPlay.lnk"
  Delete "$SMPROGRAMS\NeoPlay\NeoPlay.lnk"
  Delete "$SMPROGRAMS\NeoPlay\Uninstall NeoPlay.lnk"
  RMDir "$SMPROGRAMS\NeoPlay"
  !include "${RUNTIME_UNINSTALL}"
  Delete "$INSTDIR\LICENSE.md"
  Delete "$INSTDIR\README-WINDOWS.txt"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  RMDir /r "$LOCALAPPDATA\NeoPlay"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoPlay"
  DeleteRegKey HKCU "Software\NeoStation\NeoPlay"
  DeleteRegKey /ifempty HKCU "Software\NeoStation"
SectionEnd