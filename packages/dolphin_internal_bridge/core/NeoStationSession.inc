// NeoStation session preferences and upstream DolphiniOS input profiles.
// SPDX-License-Identifier: GPL-2.0-or-later
std::string g_input_modes[2][4];

void ResetInputProfiles()
{
  for (auto& system : g_input_modes)
    for (auto& mode : system) mode.clear();
}

std::string SessionPreferencesPath()
{
  return g_user_directory + "/Config/NeoStationSession.ini";
}

void ApplyConsolePreferences()
{
  Common::IniFile preferences;
  if (!preferences.Load(SessionPreferencesPath())) return;
  auto* console = preferences.GetOrCreateSection("Console");
  int value = -1;
  if (console->Get("WiiLanguage", &value, -1) && value >= 0 && value <= 9)
    Config::SetBase(Config::SYSCONF_LANGUAGE, static_cast<u32>(value));
  if (console->Get("GCLanguage", &value, -1) && value >= 0 && value <= 5)
    Config::SetBase(Config::MAIN_GC_LANGUAGE, value);
  // The upstream loader refuses to write a running NAND. Called after join
  // during restart/shutdown, and before boot during initialization.
  if (!Core::IsRunning(Core::System::GetInstance())) Config::Save();
}

std::string InputSection(bool wii, int slot, const std::string& mode)
{
  return std::string(wii ? "Wii" : "GC") + std::to_string(slot + 1) + "." + mode;
}

void StoreInputProfile(bool wii, int slot)
{
  if (g_input_modes[wii][slot].empty()) return;
  auto* config = DOLInputConfig(wii);
  if (!config || slot >= config->GetControllerCount()) return;
  Common::IniFile profiles;
  profiles.Load(SessionPreferencesPath());
  config->GetController(slot)->SaveConfig(
      profiles.GetOrCreateSection(InputSection(wii, slot, g_input_modes[wii][slot])));
  profiles.Save(SessionPreferencesPath());
}

bool IsDesktopDefault(ControllerEmu::EmulatedController* controller, bool wii)
{
  // Upgrade the unusable keyboard defaults from build 196, preserving custom
  // mappings (including qualified inputs and deliberately cleared bindings).
  std::vector<DOLControlEntry> entries;
  DOLCollectControls(controller, "", entries);
  const std::map<std::string, std::string> buttons = wii ?
      std::map<std::string, std::string>{{"Buttons/A", "`Left Click`"},
          {"Buttons/B", "`Right Click`"}, {"Buttons/1", "`1`"},
          {"Buttons/2", "`2`"}, {"Buttons/-", "Q"}, {"Buttons/+", "E"}} :
      std::map<std::string, std::string>{{"Buttons/A", "`X`"},
          {"Buttons/B", "`Z`"}, {"Buttons/X", "`C`"},
          {"Buttons/Y", "`S`"}, {"Buttons/Z", "`D`"}, {"Buttons/Start", "`Return`"}};
  size_t matches = 0;
  for (const auto& entry : entries)
  {
    const auto& expression = entry.control->control_ref->GetExpression();
    if (expression.find(':') != std::string::npos ||
        expression.find("Button ") != std::string::npos) return false;
    const auto found = buttons.find(entry.id);
    if (found != buttons.end())
    {
      if (expression != found->second) return false;
      ++matches;
    }
  }
  return matches == buttons.size();
}

bool SelectInputProfile(bool wii, int slot, const std::string& device_name)
{
  auto* config = DOLInputConfig(wii);
  if (!config || slot < 0 || slot >= config->GetControllerCount()) return false;
  auto* controller = config->GetController(slot);
  if (!controller) return false;
  ciface::Core::DeviceQualifier qualifier;
  qualifier.FromString(device_name);
  const auto device = g_controller_interface.FindDevice(qualifier);
  if (!device || (device->GetSource() != "MFi" && device->GetName() != "Touchscreen"))
    return false;
  const std::string mode = device->GetSource() == "MFi" ? "Physical" : "Touch";
  auto& previous_mode = g_input_modes[wii][slot];
  if (previous_mode == mode)
  {
    // Changing/reconnecting a physical controller preserves the user's mapping.
    controller->SetDefaultDevice(device_name);
    controller->UpdateReferences(g_controller_interface);
    config->SaveConfig();
    StoreInputProfile(wii, slot);
    return true;
  }
  StoreInputProfile(wii, slot);
  Common::IniFile profiles;
  profiles.Load(SessionPreferencesPath());
  const auto section_name = InputSection(wii, slot, mode);
  const auto* saved = profiles.GetSection(section_name);
  Common::IniFile defaults;
  const std::string path = g_system_directory + "/Profiles/" + (wii ? "Wiimote/" : "GCPad/") +
      (mode == "Physical" ? "Physical Controller.ini" : "Touchscreen.ini");
  if (!saved && !defaults.Load(path)) return false;
  Common::IniFile::Section selected = saved ? *saved : *defaults.GetOrCreateSection("Profile");
  controller->LoadConfig(&selected);
  controller->SetDefaultDevice(device_name);
  controller->UpdateReferences(g_controller_interface);
  previous_mode = mode;
  if (wii) Config::SetBaseOrCurrent(Config::GetInfoForWiimoteSource(slot), WiimoteSource::Emulated);
  config->SaveConfig();
  StoreInputProfile(wii, slot);
  Log("input.profile_selected", wii ? "Wii controller profile selected." : "GameCube controller profile selected.");
  return true;
}

void ConfigurePhysicalControllers()
{
  if (!g_devices_changed.exchange(false)) return;
  auto lock = ControllerEmu::EmulatedController::GetStateLock();
  std::vector<std::string> physical;
  for (const auto& device : g_controller_interface.GetAllDevices())
  {
    if (device->GetSource() != "MFi") continue;
    ciface::Core::DeviceQualifier qualifier;
    qualifier.FromDevice(device.get());
    physical.push_back(qualifier.ToString());
  }
  // Player one follows the iOS controller connection, like DolphiniOS. Other
  // slots retain their explicit configuration and can be assigned in the menu.
  for (bool wii : {false, true})
  {
    auto* config = DOLInputConfig(wii);
    if (!config || config->GetControllerCount() == 0) continue;
    auto* controller = config->GetController(0);
    if (!controller) continue;
    auto& mode = g_input_modes[wii][0];
    if (mode.empty())
    {
      if (!IsDesktopDefault(controller, wii))
      {
        mode = controller->GetDefaultDevice().source == "MFi" ? "Physical" : "Touch";
        StoreInputProfile(wii, 0);
      }
    }
    std::string wanted = physical.empty() ? (wii ? "iOS/4/Touchscreen" : "iOS/0/Touchscreen") : physical.front();
    const auto current = controller->GetDefaultDevice();
    if (!physical.empty() && current.source == "MFi" && g_controller_interface.FindDevice(current))
      wanted = current.ToString();
    if (mode.empty() || current.ToString() != wanted)
      SelectInputProfile(wii, 0, wanted);
  }
  Log("input.devices_changed", "Physical controllers: " + std::to_string(physical.size()));
}
