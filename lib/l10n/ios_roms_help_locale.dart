import 'package:flutter/widgets.dart';

abstract final class IosRomsHelpLocale {
  static const Map<String, String> _body = {
    'en': 'NeoStation looks for games in its own folder:\n\n{path}\n\nTo add games: open the Files app on this iPhone, go to "On My iPhone" (or "On My iPad") → "NeoStation" → "roms", and copy your game files there, organized into subfolders per system (for example "snes", "gba", "psx"). You can also drag files in from a computer with Finder or iTunes file sharing.\n\nOnce your files are in place, tap this button again to scan for them.',
    'fr': 'NeoStation recherche les jeux dans son propre dossier :\n\n{path}\n\nPour ajouter des jeux : ouvrez l’app Fichiers sur cet iPhone, allez dans « Sur mon iPhone » (ou « Sur mon iPad ») → « NeoStation » → « roms », puis copiez-y vos fichiers de jeu, organisés dans des sous-dossiers par système (par exemple « snes », « gba », « psx »). Vous pouvez également glisser des fichiers depuis un ordinateur avec Finder ou le partage de fichiers iTunes.\n\nUne fois vos fichiers en place, touchez de nouveau ce bouton pour les analyser.',
    'de': 'NeoStation sucht Spiele in seinem eigenen Ordner:\n\n{path}\n\nSo fügst du Spiele hinzu: Öffne die Dateien-App auf diesem iPhone, gehe zu „Auf meinem iPhone“ (oder „Auf meinem iPad“) → „NeoStation“ → „roms“ und kopiere deine Spieldateien dorthin. Ordne sie in Unterordnern nach System (zum Beispiel „snes“, „gba“, „psx“). Du kannst Dateien auch über Finder oder die iTunes-Dateifreigabe von einem Computer hineinziehen.\n\nSobald die Dateien vorhanden sind, tippe erneut auf diese Schaltfläche, um sie zu scannen.',
    'es': 'NeoStation busca los juegos en su propia carpeta:\n\n{path}\n\nPara añadir juegos: abre la app Archivos en este iPhone, ve a «En mi iPhone» (o «En mi iPad») → «NeoStation» → «roms» y copia allí los archivos de tus juegos, organizados en subcarpetas por sistema (por ejemplo «snes», «gba», «psx»). También puedes arrastrar archivos desde un ordenador mediante Finder o el uso compartido de archivos de iTunes.\n\nCuando los archivos estén en su sitio, vuelve a tocar este botón para analizarlos.',
    'it': 'NeoStation cerca i giochi nella propria cartella:\n\n{path}\n\nPer aggiungere giochi: apri l’app File su questo iPhone, vai in «Sul mio iPhone» (o «Sul mio iPad») → «NeoStation» → «roms» e copia lì i file dei giochi, organizzandoli in sottocartelle per sistema (ad esempio «snes», «gba», «psx»). Puoi anche trascinare i file da un computer tramite Finder o la condivisione file di iTunes.\n\nQuando i file sono al loro posto, tocca di nuovo questo pulsante per eseguire la scansione.',
    'pt': 'O NeoStation procura jogos na sua própria pasta:\n\n{path}\n\nPara adicionar jogos: abra a app Ficheiros neste iPhone, vá a «No meu iPhone» (ou «No meu iPad») → «NeoStation» → «roms» e copie os ficheiros dos jogos para lá, organizados em subpastas por sistema (por exemplo «snes», «gba», «psx»). Também pode arrastar ficheiros a partir de um computador com o Finder ou a partilha de ficheiros do iTunes.\n\nQuando os ficheiros estiverem no lugar, toque novamente neste botão para os analisar.',
    'ru': 'NeoStation ищет игры в собственной папке:\n\n{path}\n\nЧтобы добавить игры, откройте приложение «Файлы» на этом iPhone, перейдите в «На моём iPhone» (или «На моём iPad») → «NeoStation» → «roms» и скопируйте туда файлы игр, разложив их по подпапкам систем (например «snes», «gba», «psx»). Файлы также можно перетащить с компьютера через Finder или общий доступ к файлам iTunes.\n\nКогда файлы будут на месте, снова нажмите эту кнопку, чтобы выполнить сканирование.',
    'id': 'NeoStation mencari game di folder miliknya sendiri:\n\n{path}\n\nUntuk menambahkan game: buka aplikasi Files di iPhone ini, buka “Di iPhone Saya” (atau “Di iPad Saya”) → “NeoStation” → “roms”, lalu salin file game ke sana dan kelompokkan dalam subfolder per sistem (misalnya “snes”, “gba”, “psx”). Anda juga dapat menyeret file dari komputer melalui Finder atau berbagi file iTunes.\n\nSetelah file berada di tempatnya, ketuk tombol ini lagi untuk memindainya.',
    'ja': 'NeoStation は専用フォルダー内のゲームを検索します。\n\n{path}\n\nゲームを追加するには、この iPhone で「ファイル」App を開き、「このiPhone内」（または「このiPad内」）→「NeoStation」→「roms」へ進み、ゲームファイルをシステムごとのサブフォルダー（例:「snes」「gba」「psx」）に整理してコピーしてください。Finder または iTunes のファイル共有を使ってコンピューターからドラッグすることもできます。\n\nファイルを配置したら、このボタンをもう一度タップしてスキャンします。',
    'ko': 'NeoStation은 자체 폴더에서 게임을 찾습니다.\n\n{path}\n\n게임을 추가하려면 이 iPhone에서 파일 앱을 열고 “나의 iPhone” (또는 “나의 iPad”) → “NeoStation” → “roms”로 이동한 뒤 게임 파일을 시스템별 하위 폴더(예: “snes”, “gba”, “psx”)에 정리하여 복사하세요. Finder 또는 iTunes 파일 공유를 사용해 컴퓨터에서 파일을 드래그할 수도 있습니다.\n\n파일을 넣은 뒤 이 버튼을 다시 탭하면 스캔합니다.',
    'zh': 'NeoStation 会在自己的文件夹中查找游戏：\n\n{path}\n\n要添加游戏：在这台 iPhone 上打开“文件”App，进入“我的 iPhone”（或“我的 iPad”）→“NeoStation”→“roms”，然后把游戏文件复制到其中，并按系统整理到子文件夹（例如“snes”“gba”“psx”）。你也可以通过 Finder 或 iTunes 文件共享从电脑拖入文件。\n\n文件放好后，再次点按此按钮即可扫描。',
    'zh_Hant': 'NeoStation 會在自己的資料夾中尋找遊戲：\n\n{path}\n\n若要新增遊戲：在這台 iPhone 上開啟「檔案」App，前往「我的 iPhone」（或「我的 iPad」）→「NeoStation」→「roms」，然後將遊戲檔案複製到其中，並依系統整理到子資料夾（例如「snes」「gba」「psx」）。你也可以透過 Finder 或 iTunes 檔案共享從電腦拖入檔案。\n\n檔案放好後，再次點按此按鈕即可掃描。',
  };

  static String body(BuildContext context, String path) {
    final locale = Localizations.localeOf(context);
    var key = locale.languageCode;
    if (key == 'zh') {
      final script = locale.scriptCode?.toLowerCase();
      final country = locale.countryCode?.toUpperCase();
      if (script == 'hant' || country == 'TW' || country == 'HK' || country == 'MO') {
        key = 'zh_Hant';
      }
    }
    return (_body[key] ?? _body['en']!).replaceAll('{path}', path);
  }
}
