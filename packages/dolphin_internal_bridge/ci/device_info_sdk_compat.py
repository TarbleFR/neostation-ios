"""Keep the locked device_info_plus API buildable with the pinned older SDK.

Only its CocoaPods target receives a declaration-only compatibility header.
No dependency source, lockfile, runtime implementation or emulator is changed.
The upstream call retains its @available(iOS 26.1, *) runtime check.
"""
from pathlib import Path

HEADER = '''// NeoStation build compatibility; no Foundation method is implemented here.
// device_info_plus 13.2.0 calls this public getter behind @available(iOS 26.1, *).
// Xcode 16.4 cannot see its declaration even though that runtime check is valid.
#import <Foundation/Foundation.h>
#import <Availability.h>

#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED < 260100
@interface NSProcessInfo (NeoStationDeviceInfoSDKCompatibility)
- (BOOL)isiOSAppOnVision API_AVAILABLE(ios(26.1));
@end
#endif
'''

RUBY = '''# A declaration-only header, confined to the device_info_plus Pod.
# Preserve every other Pod target and the pre-existing compiler flags.
module NeoStationDeviceInfoSDKCompatibility
  def self.apply(installer)
    header = File.expand_path('NSProcessInfoVisionCompatibility.h', __dir__)
    raise "Missing SDK compatibility header: #{header}" unless File.file?(header)
    installer.pods_project.targets.each do |target|
      next unless target.name == 'device_info_plus'
      target.build_configurations.each do |config|
        previous = config.build_settings['OTHER_CFLAGS']
        flags = previous.is_a?(Array) ? previous.dup : [previous || '$(inherited)']
        include_pair = ['-include', "\\\"#{header}\\\""]
        flags.concat(include_pair) unless flags.each_cons(2).any? { |pair| pair == include_pair }
        config.build_settings['OTHER_CFLAGS'] = flags
      end
    end
  end
end
'''

BEGIN = '# NEOSTATION_DEVICE_INFO_SDK_COMPAT_BEGIN'
END = '# NEOSTATION_DEVICE_INFO_SDK_COMPAT_END'
HOOK = f'''{BEGIN}
  require_relative 'NeoStationBuildCompatibility/device_info_sdk_compat'
  NeoStationDeviceInfoSDKCompatibility.apply(installer)
{END}'''


def install(ios: Path) -> None:
    """Install once into the generated host, after Flutter generated its Podfile."""
    podfile = ios / 'Podfile'
    text = podfile.read_text(encoding='utf-8')
    anchor = 'post_install do |installer|'
    if text.count(anchor) != 1:
        raise ValueError('Expected one CocoaPods post_install hook; review SDK integration')
    if BEGIN in text or END in text:
        if text.count(HOOK) != 1 or text.count(BEGIN) != 1 or text.count(END) != 1:
            raise ValueError('SDK compatibility hook changed; refusing to overwrite it')
    else:
        text = text.replace(anchor, anchor + '\n' + HOOK, 1)
    destination = ios / 'NeoStationBuildCompatibility'
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'NSProcessInfoVisionCompatibility.h').write_text(HEADER, encoding='utf-8')
    (destination / 'device_info_sdk_compat.rb').write_text(RUBY, encoding='utf-8')
    podfile.write_text(text, encoding='utf-8')
