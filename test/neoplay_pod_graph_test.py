"""Real CocoaPods graph/validator regression; not Flutter or device execution.

Flutter and the unrelated dynamic pod are metadata fixtures. NeoPlay's podspec,
Swift source paths and the actual pinned Google Cast distribution are real.
The complete IPA build remains the real Flutter/native linkage proof.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PODSPEC = ROOT / 'packages/neoplay_bridge/ios/neoplay_bridge.podspec'
CREATE = r'''
require 'xcodeproj'
project = Xcodeproj::Project.new(File.join(ARGV.fetch(0), 'Runner.xcodeproj'))
project.new_target(:application, 'Runner', :ios, '18.0')
project.save
'''
PODFILE = r'''
platform :ios, '18.0'
use_frameworks!
target 'Runner' do
  pod 'Flutter', :path => 'fixtures/Flutter'
  pod 'UnrelatedDynamicFixture', :path => 'fixtures/UnrelatedDynamicFixture'
  pod 'neoplay_bridge', :path => 'packages/neoplay_bridge/ios'
end
post_install do |installer|
  require 'json'
  graph = installer.pod_targets.to_h do |target|
    [target.pod_name, {linkage: target.build_type.linkage.to_s, packaging: target.build_type.packaging.to_s}]
  end
  File.write(File.join(__dir__, 'graph.json'), JSON.generate(graph))
end
'''

class NeoPlayPodGraph(unittest.TestCase):
    def exercise(self, root, static):
        ios = root / ('corrected' if static else 'original')
        ios.mkdir()
        bridge = ios / 'packages/neoplay_bridge/ios'
        bridge.mkdir(parents=True)
        text = PODSPEC.read_text()
        self.assertEqual(text.count('  s.static_framework = true\n'), 1)
        if not static:
            text = text.replace('  s.static_framework = true\n', '')
        (bridge / PODSPEC.name).write_text(text)
        (bridge / 'Classes').symlink_to(PODSPEC.parent / 'Classes', target_is_directory=True)
        shutil.copyfile(ROOT / 'LICENSE.md', ios / 'LICENSE.md')
        for name in ('Flutter', 'UnrelatedDynamicFixture'):
            folder = ios / 'fixtures' / name
            folder.mkdir(parents=True)
            (folder / 'dummy.m').write_text('void metadata_fixture_only(void) {}\n')
            (folder / (name + '.podspec')).write_text(
                "Pod::Spec.new do |s|\n  s.name = '" + name + "'\n"
                "  s.version = '1.0.0'\n  s.summary = 'Dependency graph metadata fixture'\n"
                "  s.homepage = 'https://github.com/TarbleFR/neostation-ios'\n"
                "  s.license = { :type => 'MIT', :text => 'Metadata fixture only' }\n"
                "  s.author = 'NeoStation'\n  s.source = { :path => '.' }\n"
                "  s.platform = :ios, '18.0'\n  s.source_files = 'dummy.m'\nend\n")
        (ios / 'Podfile').write_text(PODFILE)
        subprocess.run(['ruby', '-e', CREATE, str(ios)], check=True)
        # Never monkey-patch or disable CocoaPods TargetValidator.
        environment = dict(os.environ)
        for key in ('BUNDLE_GEMFILE', 'BUNDLE_PATH'):
            environment.pop(key, None)
        result = subprocess.run(['pod', 'install', '--project-directory=' + str(ios)],
                                text=True, capture_output=True, env=environment, timeout=180)
        return ios, result

    def test_demonstrated_conflict_is_rejected_and_only_neoplay_linkage_changes(self):
        with tempfile.TemporaryDirectory(prefix='neoplay-pod-graph-') as folder:
            root = Path(folder)
            old, rejected = self.exercise(root, False)
            self.assertNotEqual(rejected.returncode, 0, rejected.stdout + rejected.stderr)
            self.assertIn('transitive dependencies that include statically linked binaries', rejected.stdout + rejected.stderr)
            self.assertIn('GoogleCast.xcframework', rejected.stdout + rejected.stderr)
            corrected, accepted = self.exercise(root, True)
            self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
            graph = json.loads((corrected / 'graph.json').read_text())
            self.assertEqual(graph['neoplay_bridge'], {'linkage': 'static', 'packaging': 'framework'})
            self.assertEqual(graph['google-cast-sdk']['linkage'], 'static')
            self.assertEqual(graph['Flutter'], {'linkage': 'dynamic', 'packaging': 'framework'})
            self.assertEqual(graph['UnrelatedDynamicFixture'], {'linkage': 'dynamic', 'packaging': 'framework'})
            self.assertEqual((old / 'Podfile').read_text(), (corrected / 'Podfile').read_text())
            report = {'passed': True, 'sourceCommit': os.environ['GITHUB_SHA'],
                      'podspecSHA256': hashlib.sha256(PODSPEC.read_bytes()).hexdigest(),
                      'oldTransitiveConflictRejected': True, 'correctedGraph': graph,
                      'FlutterMetadataFixtureOnly': True, 'physicalDeviceValidated': False}
            output = ROOT / 'build/neoplay-native/pod-graph.json'
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(report, indent=2) + '\n')
            print('PASS real CocoaPods TargetValidator: original rejected, static NeoPlay accepted; unrelated dynamic linkage retained')

if __name__ == '__main__':
    unittest.main()
