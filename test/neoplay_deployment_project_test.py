"""Execute the real xcodeproj configurator; required on the Apple CI runner."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('neoplay_config', ROOT / 'build-utils/configure_neoplay_ios.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

CREATE = r'''
require 'xcodeproj'
project = Xcodeproj::Project.new(File.join(ARGV.fetch(0), 'Runner.xcodeproj'))
runner = project.new_target(:application, 'Runner', :ios, '17.4')
runner.build_configurations.first.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
runner.build_configurations.each { |c| c.build_settings['OTHER_LDFLAGS'] = ['-keep-sentinel'] }
['DolphinJITHelper', 'RPCS3JITHelper', 'ARMSX2JITHelper', 'NeoSwapDonor'].each do |name|
  project.new_target(:app_extension, name, :ios, '17.4')
end
project.save
'''
AUDIT = r'''
require 'xcodeproj'
require 'json'
project = Xcodeproj::Project.open(File.join(ARGV.fetch(0), 'Runner.xcodeproj'))
puts JSON.generate({
  project: project.build_configurations.map(&:to_hash),
  targets: project.targets.to_h { |t| [t.name, t.to_hash] },
  configurations: project.targets.to_h { |t| [t.name, t.build_configurations.map(&:to_hash)] }
})
'''

class GeneratedDeploymentProject(unittest.TestCase):
    def test_real_runner_change_preserves_every_unrelated_target_and_setting(self):
        with tempfile.TemporaryDirectory() as folder:
            ios = Path(folder)
            (ios / 'Flutter').mkdir()
            (ios / 'Podfile').write_text("platform :ios, '17.4'\n")
            (ios / 'Flutter/AppFrameworkInfo.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '17.4'}))
            # -e is a Ruby argument, not a repository script.
            prefix = ['bundle', 'exec'] if config.os.environ.get('BUNDLE_GEMFILE') else []
            subprocess.run(prefix + ['ruby', '-e', CREATE, str(ios)], check=True)
            audit = lambda: json.loads(subprocess.check_output(prefix + ['ruby', '-e', AUDIT, str(ios)], text=True))
            before = audit()
            config.configure_deployment_target(ios)
            after = audit()
            self.assertEqual(before['project'], after['project'])
            self.assertEqual(before['targets'], after['targets'])
            for target, original in before['configurations'].items():
                if target != 'Runner':
                    self.assertEqual(original, after['configurations'][target], target)
                    continue
                for old, new in zip(original, after['configurations'][target]):
                    minimum = old['buildSettings']['IPHONEOS_DEPLOYMENT_TARGET']
                    old['buildSettings']['IPHONEOS_DEPLOYMENT_TARGET'] = minimum if config.version(minimum) >= config.version('18.0') else '18.0'
                    self.assertEqual(old, new)
            paths = ['Podfile', 'Runner.xcodeproj/project.pbxproj', 'Flutter/AppFrameworkInfo.plist']
            first = [(ios / path).read_bytes() for path in paths]
            config.configure_deployment_target(ios)
            self.assertEqual(first, [(ios / path).read_bytes() for path in paths])

if __name__ == '__main__':
    unittest.main()
