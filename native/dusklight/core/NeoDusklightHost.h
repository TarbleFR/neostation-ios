#pragma once

#ifdef __cplusplus
extern "C" {
#endif
const char* NeoDusklight_ResourcesPath(void);
const char* NeoDusklight_CachePath(void);
void* NeoDusklight_WindowScene(void);
void NeoDusklight_WindowReady(void* sdl_window);
void NeoDusklight_FirstFrame(void);
void NeoDusklight_WakeGameThreads(void);
void NeoDusklight_JoinGameThreads(void);
#ifdef __cplusplus
}
#endif
