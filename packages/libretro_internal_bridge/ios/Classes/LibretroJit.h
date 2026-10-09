#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// True when the kernel reports CS_DEBUGGED for NeoStation's own process.
FOUNDATION_EXPORT BOOL LibretroHostIsDebugged(void);

/// What RETRO_ENVIRONMENT_GET_JIT_CAPABLE reports. libretro cores allocate
/// executable memory themselves, which only works while the process is
/// debugged and the OS does not require the iOS 26 debugger handshake that
/// NeoStation performs for its other engines. The answer is measured at
/// launch, never inferred from a previous session or an available route.
FOUNDATION_EXPORT BOOL LibretroJitUsableByCores(void);

NS_ASSUME_NONNULL_END
