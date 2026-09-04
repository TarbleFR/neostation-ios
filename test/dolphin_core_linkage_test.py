"""Target-local link configuration; real symbol resolution is checked by Xcode."""
from __future__ import annotations

import json
from pathlib import Path
import shlex
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
PODSPEC = ROOT / 'packages/dolphin_internal_bridge/ios/dolphin_internal_bridge.podspec'


class DolphinCoreLinkageTests(unittest.TestCase):
    def test_bridge_links_its_vendored_core_without_global_settings(self) -> None:
        ruby = shutil.which('ruby')
        if ruby is None:
            self.skipTest('Ruby is needed to evaluate the podspec DSL')
        # Evaluate the actual Ruby assignments with a recording DSL, not a copy
        # of the settings. CocoaPods and the native linker are exercised by CI.
        script = r'''
require 'json'
module Pod
  class Spec
    attr_reader :values
    def initialize
      @values = {}
      yield self
      puts JSON.generate(@values)
    end
    def ios; self; end
    def dependency(*args); end
    def method_missing(name, *args)
      raise "Unexpected podspec call #{name}" unless name.to_s.end_with?('=')
      @values[name.to_s.delete_suffix('=')] = args.length == 1 ? args.first : args
    end
  end
end
load ARGV.fetch(0)
'''
        result = subprocess.run([ruby, '-e', script, str(PODSPEC)],
                                check=True, capture_output=True, text=True, timeout=15)
        spec = json.loads(result.stdout)
        self.assertEqual(spec['name'], 'dolphin_internal_bridge')
        self.assertEqual(spec['vendored_frameworks'], 'Frameworks/DolphinCore.framework')
        self.assertNotIn('user_target_xcconfig', spec)
        flags = shlex.split(spec['pod_target_xcconfig']['OTHER_LDFLAGS'])
        self.assertIn('$(inherited)', flags)
        self.assertIn('-ObjC', flags)
        libraries = [flags[i + 1] for i, flag in enumerate(flags[:-1]) if flag == '-framework']
        self.assertEqual(libraries, ['DolphinCore'])
        self.assertNotIn('-undefined', flags)
        self.assertNotIn('dynamic_lookup', flags)
        self.assertNotIn('-weak_framework', flags)


if __name__ == '__main__':
    unittest.main()
