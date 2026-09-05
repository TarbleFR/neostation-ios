// Native Dolphin slots, shared by GameCube and Wii. SPDX-License-Identifier: GPL-2.0-or-later
namespace
{
bool DOLStateSessionReady()
{
  auto& system = Core::System::GetInstance();
  return g_initialized && g_running && !g_cleanup_started &&
      Core::GetState(system) == Core::State::Paused;
}

std::string DOLStatePath(int slot)
{
  if (slot < 1 || slot > 10) return {};
  const auto game_id = SConfig::GetInstance().GetGameID();
  if ((game_id.size() != 4 && game_id.size() != 6) ||
      !std::all_of(game_id.begin(), game_id.end(), [](unsigned char c) {
        return (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
      })) return {};
  return File::GetUserPath(D_STATESAVES_IDX) + game_id +
      (slot < 10 ? ".s0" : ".s") + std::to_string(slot);
}

bool DOLStateHeaderMatches(const std::string& path)
{
  State::StateHeader header;
  char expected[6]{};
  const auto id = SConfig::GetInstance().GetGameID();
  memcpy(expected, id.data(), std::min(id.size(), sizeof(expected)));
  return State::ReadHeader(path, header) && memcmp(expected, header.legacy_header.game_id, 6) == 0;
}

bool DOLStatePathIsSafe(const std::string& path)
{
  if (path.empty()) return false;
  NSString* root = [DOLString(g_user_directory) stringByStandardizingPath];
  NSString* name = DOLString(path);
  NSString* state_root = [root stringByAppendingPathComponent:@"StateSaves"];
  if (![[name stringByDeletingLastPathComponent] isEqual:state_root]) return false;
  for (NSString* cursor = name; ; cursor = [cursor stringByDeletingLastPathComponent]) {
    NSError* error = nil;
    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:cursor error:&error];
    if (attributes) {
      if (![attributes[NSFileType] isEqual:[cursor isEqual:name] ? NSFileTypeRegular : NSFileTypeDirectory]) return false;
    } else if (![error.domain isEqual:NSCocoaErrorDomain] ||
        (error.code != NSFileNoSuchFileError && error.code != NSFileReadNoSuchFileError)) return false;
    if ([cursor isEqual:root]) break;
  }
  return true;
}
}

extern "C" __attribute__((visibility("default")))
char* neostation_dolphin_state_snapshot(void)
{
  Log("savestate.snapshot.begin", "Reading the paused game's state slots.");
  __block char* result = nullptr;
  DOLHostQueueRunSync(^{
    @autoreleasepool {
    if (!DOLStateSessionReady()) return;
    NSMutableArray* slots = [NSMutableArray array];
    for (int slot = 1; slot <= 10; ++slot)
    {
      const auto path = DOLStatePath(slot);
      if (path.empty()) return;
      NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:DOLString(path) error:nil];
      const bool exists = attributes != nil;
      NSDate* modified = attributes[NSFileModificationDate];
      [slots addObject:@{@"slot": @(slot), @"exists": @(exists),
          @"loadable": @(exists && DOLStatePathIsSafe(path) && DOLStateHeaderMatches(path)),
          @"modified": @(modified ? modified.timeIntervalSince1970 : 0),
          @"filename": [DOLString(path) lastPathComponent]}];
    }
    NSData* encoded = [NSJSONSerialization dataWithJSONObject:@{@"slots": slots} options:0 error:nil];
    NSString* json = encoded ? [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] : nil;
    // Copy before the host queue's autorelease pool drains. The C ABI owns only
    // these bytes; no Foundation object is borrowed across the queue boundary.
    if (json.UTF8String) result = strdup(json.UTF8String);
    }
  });
  Log("savestate.snapshot.complete", result ? "Slot list copied." : "Slot list unavailable.");
  return result;
}

extern "C" __attribute__((visibility("default")))
int32_t neostation_dolphin_state_operation(int32_t slot, int32_t load)
{
  if (slot < 1 || slot > 10 || (load != 0 && load != 1)) return 0;
  Log(load ? "savestate.load.begin" : "savestate.save.begin", "Slot " + std::to_string(slot));
  __block bool success = false;
  // All bridge operations enter on the same serial runtime queue as Stop/Restart.
  // State's synchronous APIs acquire the CPU lock internally. An outer CPU lock
  // here would invert their locks and can deadlock the emulation thread.
  DOLHostQueueRunSync(^{
    if (!DOLStateSessionReady()) return;
    const auto path = DOLStatePath(slot);
    if (!DOLStatePathIsSafe(path)) return;
    auto& system = Core::System::GetInstance();
    if (load)
    {
      if (!DOLStateHeaderMatches(path)) return;
      State::LoadAs(system, path); // Waits for CPU work; core checks version and undoes failed loads.
    }
    else
    {
      State::EnableCompression(true);
      State::SaveAs(system, path, true); // Also waits for compression and the completed disk write.
    }
    success = State::NeoStationLastOperationSucceeded();
    // RunOnCPUThread preserves the original pause state. Re-pausing an already
    // paused core needlessly re-enters Wiimote, rumble and UI state callbacks.
    if (Core::GetState(system) == Core::State::Running)
      Core::SetState(system, Core::State::Paused);
  });
  Log(load ? "savestate.load" : "savestate.save",
      "Slot " + std::to_string(slot) + (success ? " completed." : " failed."));
  return success ? 1 : 0;
}
