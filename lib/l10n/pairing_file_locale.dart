import 'package:flutter/widgets.dart';

/// Localized strings dedicated to the iOS pairing-file flow.
class PairingFileLocale {
  PairingFileLocale._();

  static const title = 'title';
  static const configured = 'configured';
  static const notConfigured = 'notConfigured';
  static const configuredSubtitle = 'configuredSubtitle';
  static const notConfiguredSubtitle = 'notConfiguredSubtitle';
  static const importAction = 'importAction';
  static const replaceAction = 'replaceAction';
  static const pickerTitle = 'pickerTitle';
  static const imported = 'imported';
  static const replaced = 'replaced';
  static const invalidExtension = 'invalidExtension';
  static const invalidFile = 'invalidFile';
  static const importFailed = 'importFailed';
  static const setupTitle = 'setupTitle';
  static const setupBody = 'setupBody';
  static const chooseFile = 'chooseFile';
  static const later = 'later';
  static const checking = 'checking';
  static const jitRequired = 'jitRequired';

  static String get(BuildContext context, String key) {
    final locale = Localizations.localeOf(context);
    final localeKey = _localeKey(locale);
    return _values[localeKey]?[key] ?? _values['en']![key] ?? key;
  }

  static String _localeKey(Locale locale) {
    if (locale.languageCode == 'zh') {
      final script = locale.scriptCode?.toLowerCase();
      final country = locale.countryCode?.toUpperCase();
      if (script == 'hant' ||
          country == 'TW' ||
          country == 'HK' ||
          country == 'MO') {
        return 'zh_Hant';
      }
      return 'zh';
    }
    return _values.containsKey(locale.languageCode)
        ? locale.languageCode
        : 'en';
  }

  static const Map<String, Map<String, String>> _values = {
    'en': {
      title: 'Pairing File',
      configured: 'Configured',
      notConfigured: 'Not configured',
      configuredSubtitle:
          'Ready for emulators that require JIT, including MeloNX, ARMSX2, RPCS3 and others. Select this option to replace it.',
      notConfiguredSubtitle:
          'Essential for launching emulators that require JIT, such as MeloNX, ARMSX2, RPCS3 and others.',
      importAction: 'Import Pairing File',
      replaceAction: 'Replace Pairing File',
      pickerTitle: 'Select your Pairing File',
      imported: 'Pairing File imported successfully.',
      replaced: 'Pairing File replaced successfully.',
      invalidExtension: 'Please select a .mobiledevicepairing file.',
      invalidFile: 'The selected Pairing File is empty or invalid.',
      importFailed: 'The Pairing File could not be imported.',
      setupTitle: 'Pairing File',
      setupBody:
          'The Pairing File is essential for launching emulators that require JIT, such as MeloNX, ARMSX2, RPCS3 and others. Import this iPhone’s .mobiledevicepairing file once. It is stored privately inside NeoStation and can be replaced later in Settings → Tools.',
      chooseFile: 'Choose Pairing File',
      later: 'Later',
      checking: 'Checking Pairing File…',
      jitRequired:
          'A Pairing File is required to launch compatible JIT emulators.',
    },
    'de': {
      title: 'Pairing-Datei',
      configured: 'Konfiguriert',
      notConfigured: 'Nicht konfiguriert',
      configuredSubtitle:
          'Bereit für Emulatoren, die JIT benötigen, darunter MeloNX, ARMSX2, RPCS3 und weitere. Wähle diese Option, um die Datei zu ersetzen.',
      notConfiguredSubtitle:
          'Erforderlich zum Starten von Emulatoren, die JIT benötigen, z. B. MeloNX, ARMSX2, RPCS3 und weitere.',
      importAction: 'Pairing-Datei importieren',
      replaceAction: 'Pairing-Datei ersetzen',
      pickerTitle: 'Pairing-Datei auswählen',
      imported: 'Pairing-Datei wurde erfolgreich importiert.',
      replaced: 'Pairing-Datei wurde erfolgreich ersetzt.',
      invalidExtension: 'Bitte wähle eine .mobiledevicepairing-Datei aus.',
      invalidFile: 'Die ausgewählte Pairing-Datei ist leer oder ungültig.',
      importFailed: 'Die Pairing-Datei konnte nicht importiert werden.',
      setupTitle: 'Pairing-Datei',
      setupBody:
          'Die Pairing-Datei ist erforderlich, um Emulatoren zu starten, die JIT benötigen, z. B. MeloNX, ARMSX2, RPCS3 und weitere. Importiere einmal die .mobiledevicepairing-Datei dieses iPhones. Sie wird privat in NeoStation gespeichert und kann später unter Einstellungen → Werkzeuge ersetzt werden.',
      chooseFile: 'Pairing-Datei auswählen',
      later: 'Später',
      checking: 'Pairing-Datei wird geprüft…',
      jitRequired:
          'Zum Starten kompatibler JIT-Emulatoren ist eine Pairing-Datei erforderlich.',
    },
    'es': {
      title: 'Archivo de emparejamiento',
      configured: 'Configurado',
      notConfigured: 'Sin configurar',
      configuredSubtitle:
          'Listo para emuladores que requieren JIT, incluidos MeloNX, ARMSX2, RPCS3 y otros. Selecciona esta opción para reemplazarlo.',
      notConfiguredSubtitle:
          'Esencial para iniciar emuladores que requieren JIT, como MeloNX, ARMSX2, RPCS3 y otros.',
      importAction: 'Importar archivo de emparejamiento',
      replaceAction: 'Reemplazar archivo de emparejamiento',
      pickerTitle: 'Selecciona el archivo de emparejamiento',
      imported: 'Archivo de emparejamiento importado correctamente.',
      replaced: 'Archivo de emparejamiento reemplazado correctamente.',
      invalidExtension: 'Selecciona un archivo .mobiledevicepairing.',
      invalidFile:
          'El archivo de emparejamiento seleccionado está vacío o no es válido.',
      importFailed: 'No se pudo importar el archivo de emparejamiento.',
      setupTitle: 'Archivo de emparejamiento',
      setupBody:
          'El archivo de emparejamiento es esencial para iniciar emuladores que requieren JIT, como MeloNX, ARMSX2, RPCS3 y otros. Importa una vez el archivo .mobiledevicepairing de este iPhone. Se guardará de forma privada dentro de NeoStation y podrás reemplazarlo más tarde en Ajustes → Herramientas.',
      chooseFile: 'Elegir archivo de emparejamiento',
      later: 'Más tarde',
      checking: 'Comprobando el archivo de emparejamiento…',
      jitRequired:
          'Se necesita un archivo de emparejamiento para iniciar emuladores JIT compatibles.',
    },
    'fr': {
      title: 'Pairing File',
      configured: 'Configuré',
      notConfigured: 'Non configuré',
      configuredSubtitle:
          'Prêt pour les émulateurs nécessitant le JIT, notamment MeloNX, ARMSX2, RPCS3 et d’autres. Sélectionnez cette option pour le remplacer.',
      notConfiguredSubtitle:
          'Essentiel pour lancer les émulateurs nécessitant le JIT, comme MeloNX, ARMSX2, RPCS3 et d’autres.',
      importAction: 'Importer le Pairing File',
      replaceAction: 'Remplacer le Pairing File',
      pickerTitle: 'Sélectionnez votre Pairing File',
      imported: 'Pairing File importé avec succès.',
      replaced: 'Pairing File remplacé avec succès.',
      invalidExtension: 'Veuillez sélectionner un fichier .mobiledevicepairing.',
      invalidFile: 'Le Pairing File sélectionné est vide ou invalide.',
      importFailed: 'Le Pairing File n’a pas pu être importé.',
      setupTitle: 'Pairing File',
      setupBody:
          'Le Pairing File est essentiel pour lancer les émulateurs nécessitant le JIT, comme MeloNX, ARMSX2, RPCS3 et d’autres. Importez une seule fois le fichier .mobiledevicepairing de cet iPhone. Il sera conservé dans le stockage privé de NeoStation et pourra être remplacé plus tard dans Paramètres → Outils.',
      chooseFile: 'Choisir le Pairing File',
      later: 'Plus tard',
      checking: 'Vérification du Pairing File…',
      jitRequired:
          'Un Pairing File est requis pour lancer les émulateurs compatibles nécessitant le JIT.',
    },
    'id': {
      title: 'File Pairing',
      configured: 'Dikonfigurasi',
      notConfigured: 'Belum dikonfigurasi',
      configuredSubtitle:
          'Siap untuk emulator yang memerlukan JIT, termasuk MeloNX, ARMSX2, RPCS3, dan lainnya. Pilih opsi ini untuk menggantinya.',
      notConfiguredSubtitle:
          'Penting untuk menjalankan emulator yang memerlukan JIT, seperti MeloNX, ARMSX2, RPCS3, dan lainnya.',
      importAction: 'Impor File Pairing',
      replaceAction: 'Ganti File Pairing',
      pickerTitle: 'Pilih File Pairing Anda',
      imported: 'File Pairing berhasil diimpor.',
      replaced: 'File Pairing berhasil diganti.',
      invalidExtension: 'Silakan pilih file .mobiledevicepairing.',
      invalidFile: 'File Pairing yang dipilih kosong atau tidak valid.',
      importFailed: 'File Pairing tidak dapat diimpor.',
      setupTitle: 'File Pairing',
      setupBody:
          'File Pairing sangat penting untuk menjalankan emulator yang memerlukan JIT, seperti MeloNX, ARMSX2, RPCS3, dan lainnya. Impor file .mobiledevicepairing iPhone ini satu kali. File akan disimpan secara privat di dalam NeoStation dan dapat diganti nanti di Pengaturan → Alat.',
      chooseFile: 'Pilih File Pairing',
      later: 'Nanti',
      checking: 'Memeriksa File Pairing…',
      jitRequired:
          'File Pairing diperlukan untuk menjalankan emulator JIT yang kompatibel.',
    },
    'it': {
      title: 'File di abbinamento',
      configured: 'Configurato',
      notConfigured: 'Non configurato',
      configuredSubtitle:
          'Pronto per gli emulatori che richiedono JIT, inclusi MeloNX, ARMSX2, RPCS3 e altri. Seleziona questa opzione per sostituirlo.',
      notConfiguredSubtitle:
          'Essenziale per avviare emulatori che richiedono JIT, come MeloNX, ARMSX2, RPCS3 e altri.',
      importAction: 'Importa file di abbinamento',
      replaceAction: 'Sostituisci file di abbinamento',
      pickerTitle: 'Seleziona il file di abbinamento',
      imported: 'File di abbinamento importato correttamente.',
      replaced: 'File di abbinamento sostituito correttamente.',
      invalidExtension: 'Seleziona un file .mobiledevicepairing.',
      invalidFile:
          'Il file di abbinamento selezionato è vuoto o non valido.',
      importFailed: 'Impossibile importare il file di abbinamento.',
      setupTitle: 'File di abbinamento',
      setupBody:
          'Il file di abbinamento è essenziale per avviare emulatori che richiedono JIT, come MeloNX, ARMSX2, RPCS3 e altri. Importa una sola volta il file .mobiledevicepairing di questo iPhone. Verrà conservato privatamente in NeoStation e potrà essere sostituito in seguito in Impostazioni → Strumenti.',
      chooseFile: 'Scegli file di abbinamento',
      later: 'Più tardi',
      checking: 'Verifica del file di abbinamento…',
      jitRequired:
          'È necessario un file di abbinamento per avviare emulatori JIT compatibili.',
    },
    'ja': {
      title: 'ペアリングファイル',
      configured: '設定済み',
      notConfigured: '未設定',
      configuredSubtitle:
          'MeloNX、ARMSX2、RPCS3 など、JIT を必要とするエミュレーターで使用できます。置き換えるにはこの項目を選択してください。',
      notConfiguredSubtitle:
          'MeloNX、ARMSX2、RPCS3 など、JIT を必要とするエミュレーターを起動するために不可欠です。',
      importAction: 'ペアリングファイルを読み込む',
      replaceAction: 'ペアリングファイルを置き換える',
      pickerTitle: 'ペアリングファイルを選択',
      imported: 'ペアリングファイルを読み込みました。',
      replaced: 'ペアリングファイルを置き換えました。',
      invalidExtension: '.mobiledevicepairing ファイルを選択してください。',
      invalidFile: '選択したペアリングファイルが空か、無効です。',
      importFailed: 'ペアリングファイルを読み込めませんでした。',
      setupTitle: 'ペアリングファイル',
      setupBody:
          'ペアリングファイルは、MeloNX、ARMSX2、RPCS3 など、JIT を必要とするエミュレーターを起動するために不可欠です。この iPhone の .mobiledevicepairing ファイルを一度読み込んでください。ファイルは NeoStation 内に非公開で保存され、後から「設定 → ツール」で置き換えられます。',
      chooseFile: 'ペアリングファイルを選択',
      later: '後で',
      checking: 'ペアリングファイルを確認中…',
      jitRequired:
          '対応する JIT エミュレーターを起動するにはペアリングファイルが必要です。',
    },
    'ko': {
      title: '페어링 파일',
      configured: '설정됨',
      notConfigured: '설정되지 않음',
      configuredSubtitle:
          'MeloNX, ARMSX2, RPCS3 등 JIT가 필요한 에뮬레이터에서 사용할 준비가 되었습니다. 교체하려면 이 옵션을 선택하세요.',
      notConfiguredSubtitle:
          'MeloNX, ARMSX2, RPCS3 등 JIT가 필요한 에뮬레이터를 실행하는 데 필수입니다.',
      importAction: '페어링 파일 가져오기',
      replaceAction: '페어링 파일 교체',
      pickerTitle: '페어링 파일 선택',
      imported: '페어링 파일을 성공적으로 가져왔습니다.',
      replaced: '페어링 파일을 성공적으로 교체했습니다.',
      invalidExtension: '.mobiledevicepairing 파일을 선택하세요.',
      invalidFile: '선택한 페어링 파일이 비어 있거나 올바르지 않습니다.',
      importFailed: '페어링 파일을 가져올 수 없습니다.',
      setupTitle: '페어링 파일',
      setupBody:
          '페어링 파일은 MeloNX, ARMSX2, RPCS3 등 JIT가 필요한 에뮬레이터를 실행하는 데 필수입니다. 이 iPhone의 .mobiledevicepairing 파일을 한 번 가져오세요. 파일은 NeoStation 내부에 비공개로 저장되며 나중에 설정 → 도구에서 교체할 수 있습니다.',
      chooseFile: '페어링 파일 선택',
      later: '나중에',
      checking: '페어링 파일 확인 중…',
      jitRequired:
          '호환되는 JIT 에뮬레이터를 실행하려면 페어링 파일이 필요합니다.',
    },
    'pt': {
      title: 'Arquivo de emparelhamento',
      configured: 'Configurado',
      notConfigured: 'Não configurado',
      configuredSubtitle:
          'Pronto para emuladores que exigem JIT, incluindo MeloNX, ARMSX2, RPCS3 e outros. Selecione esta opção para substituí-lo.',
      notConfiguredSubtitle:
          'Essencial para iniciar emuladores que exigem JIT, como MeloNX, ARMSX2, RPCS3 e outros.',
      importAction: 'Importar arquivo de emparelhamento',
      replaceAction: 'Substituir arquivo de emparelhamento',
      pickerTitle: 'Selecione o arquivo de emparelhamento',
      imported: 'Arquivo de emparelhamento importado com sucesso.',
      replaced: 'Arquivo de emparelhamento substituído com sucesso.',
      invalidExtension: 'Selecione um arquivo .mobiledevicepairing.',
      invalidFile:
          'O arquivo de emparelhamento selecionado está vazio ou é inválido.',
      importFailed: 'Não foi possível importar o arquivo de emparelhamento.',
      setupTitle: 'Arquivo de emparelhamento',
      setupBody:
          'O arquivo de emparelhamento é essencial para iniciar emuladores que exigem JIT, como MeloNX, ARMSX2, RPCS3 e outros. Importe uma vez o arquivo .mobiledevicepairing deste iPhone. Ele será armazenado de forma privada no NeoStation e poderá ser substituído depois em Configurações → Ferramentas.',
      chooseFile: 'Escolher arquivo de emparelhamento',
      later: 'Mais tarde',
      checking: 'Verificando o arquivo de emparelhamento…',
      jitRequired:
          'É necessário um arquivo de emparelhamento para iniciar emuladores JIT compatíveis.',
    },
    'ru': {
      title: 'Файл сопряжения',
      configured: 'Настроен',
      notConfigured: 'Не настроен',
      configuredSubtitle:
          'Готов для эмуляторов, которым требуется JIT, включая MeloNX, ARMSX2, RPCS3 и другие. Выберите этот пункт, чтобы заменить файл.',
      notConfiguredSubtitle:
          'Необходим для запуска эмуляторов, которым требуется JIT, например MeloNX, ARMSX2, RPCS3 и других.',
      importAction: 'Импортировать файл сопряжения',
      replaceAction: 'Заменить файл сопряжения',
      pickerTitle: 'Выберите файл сопряжения',
      imported: 'Файл сопряжения успешно импортирован.',
      replaced: 'Файл сопряжения успешно заменён.',
      invalidExtension: 'Выберите файл .mobiledevicepairing.',
      invalidFile: 'Выбранный файл сопряжения пуст или недействителен.',
      importFailed: 'Не удалось импортировать файл сопряжения.',
      setupTitle: 'Файл сопряжения',
      setupBody:
          'Файл сопряжения необходим для запуска эмуляторов, которым требуется JIT, например MeloNX, ARMSX2, RPCS3 и других. Один раз импортируйте файл .mobiledevicepairing этого iPhone. Он будет храниться в закрытом хранилище NeoStation, а позже его можно заменить в разделе Настройки → Инструменты.',
      chooseFile: 'Выбрать файл сопряжения',
      later: 'Позже',
      checking: 'Проверка файла сопряжения…',
      jitRequired:
          'Для запуска совместимых JIT-эмуляторов требуется файл сопряжения.',
    },
    'zh': {
      title: '配对文件',
      configured: '已配置',
      notConfigured: '未配置',
      configuredSubtitle:
          '已可用于需要 JIT 的模拟器，包括 MeloNX、ARMSX2、RPCS3 等。选择此选项可替换文件。',
      notConfiguredSubtitle:
          '这是启动需要 JIT 的模拟器（如 MeloNX、ARMSX2、RPCS3 等）所必需的。',
      importAction: '导入配对文件',
      replaceAction: '替换配对文件',
      pickerTitle: '选择配对文件',
      imported: '配对文件导入成功。',
      replaced: '配对文件替换成功。',
      invalidExtension: '请选择 .mobiledevicepairing 文件。',
      invalidFile: '所选配对文件为空或无效。',
      importFailed: '无法导入配对文件。',
      setupTitle: '配对文件',
      setupBody:
          '配对文件是启动需要 JIT 的模拟器（如 MeloNX、ARMSX2、RPCS3 等）所必需的。只需导入一次此 iPhone 的 .mobiledevicepairing 文件。文件会私密保存在 NeoStation 中，之后可在“设置 → 工具”中替换。',
      chooseFile: '选择配对文件',
      later: '稍后',
      checking: '正在检查配对文件…',
      jitRequired: '启动兼容的 JIT 模拟器需要配对文件。',
    },
    'zh_Hant': {
      title: '配對檔案',
      configured: '已設定',
      notConfigured: '未設定',
      configuredSubtitle:
          '已可用於需要 JIT 的模擬器，包括 MeloNX、ARMSX2、RPCS3 等。選擇此選項可替換檔案。',
      notConfiguredSubtitle:
          '這是啟動需要 JIT 的模擬器（例如 MeloNX、ARMSX2、RPCS3 等）所必需的。',
      importAction: '匯入配對檔案',
      replaceAction: '替換配對檔案',
      pickerTitle: '選擇配對檔案',
      imported: '配對檔案匯入成功。',
      replaced: '配對檔案替換成功。',
      invalidExtension: '請選擇 .mobiledevicepairing 檔案。',
      invalidFile: '所選配對檔案為空或無效。',
      importFailed: '無法匯入配對檔案。',
      setupTitle: '配對檔案',
      setupBody:
          '配對檔案是啟動需要 JIT 的模擬器（例如 MeloNX、ARMSX2、RPCS3 等）所必需的。只需匯入一次此 iPhone 的 .mobiledevicepairing 檔案。檔案會私密儲存在 NeoStation 中，之後可在「設定 → 工具」中替換。',
      chooseFile: '選擇配對檔案',
      later: '稍後',
      checking: '正在檢查配對檔案…',
      jitRequired: '啟動相容的 JIT 模擬器需要配對檔案。',
    },
  };
}
