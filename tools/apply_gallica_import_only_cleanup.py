from pathlib import Path

script = Path(__file__).with_name('fix_fin_library_build144.py')
namespace = {'__name__': '__main__', '__file__': str(script)}
exec(compile(script.read_text(encoding='utf-8'), str(script), 'exec'), namespace)
