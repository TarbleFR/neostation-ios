import importlib.util
from pathlib import Path
import unittest

path=Path(__file__).resolve().parents[1]/'prepare_source.py'
spec=importlib.util.spec_from_file_location('retroarch_prepare',path)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class SourceAdaptation(unittest.TestCase):
    def test_balanced_parser_handles_strings_comments_and_blocks(self):
        source='static void sample(void) { const char *s="{\\\"}"; /* } */ if (1) { /* { */ work(); } // }\n }\nnext();'
        result=module.set_body(source,'static void sample(void)','   replacement();')
        self.assertEqual(result,'static void sample(void) {\n   replacement();\n}\nnext();')

    def test_pinned_anchor_does_not_silently_patch_unknown_source(self):
        with self.assertRaises(ValueError):module.replace_once('two two','two','one','name')
        with self.assertRaises(ValueError):module.replace_once('other','two','one','name')

if __name__=='__main__':unittest.main()
