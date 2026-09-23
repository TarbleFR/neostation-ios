#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
const char* NeoDusklight_ResourcesPath(void);
const char* NeoDusklight_CachePath(void);
void* NeoDusklight_WindowScene(void);
void NeoDusklight_WindowReady(void* sdl_window);
void NeoDusklight_FirstFrame(void);
void NeoDusklight_RuntimeReady(void);
void NeoDusklight_WakeGameThreads(void);
void NeoDusklight_JoinGameThreads(void);
int NeoDusklight_InspectDisc(const char* path, char* error, size_t error_size);
int NeoDusklight_RunGame(int argc, char** argv);
int NeoDusklight_TickGame(void);
void NeoDusklight_SetGameSuspended(int suspended);
void NeoDusklight_SetAudioSuspended(int suspended);
void NeoDusklight_OpenMenu(void);
void NeoDusklight_OpenLanguageMenu(void);
void NeoDusklight_ApplyGameLanguage(void);
int NeoDusklight_LoadGameLanguage(void);
void NeoDusklight_SaveGameLanguage(int language);
int NeoDusklight_MenuVisible(void);
void NeoDusklight_ResumeGameplay(void);
int NeoDusklight_PreferredFrameRate(void);
void NeoDusklight_RequestReturn(void);
int NeoDusklight_ShouldEnableTouch(void);
void NeoDusklight_DidEnableTouch(void);
const char* NeoDusklight_UIText(const char* key);
#ifdef __cplusplus
}
#endif
