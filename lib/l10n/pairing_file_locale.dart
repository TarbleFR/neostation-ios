import 'package:flutter/widgets.dart';

/// Localized strings dedicated to the iOS pairing-file flow.
///
/// Kept separate from the generated/legacy AppLocale maps so the experimental
/// StikJIT work can evolve without rewriting every large locale file.
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
      if (script == 'hant' || country == 'TW' || country == 'HK' || country == 'MO') {
        return 'zh_Hant';
      }
      return 'zh';
    }
    return _values.containsKey(locale.languageCode) ? locale.languageCode : 'en';
  }

  static const Map<String, Map<String, String>> _values = {
    'en': {
      title: 'Pairing File',
      configured: 'Configured',
      notConfigured: 'Not configured',
      configuredSubtitle: 'Pairing file configured. Select this option to replace it.',
      notConfiguredSubtitle: 'Import this iPhone\'s .mobiledevicepairing file for built-in JIT.',
      importAction: 'Import Pairing File',
      replaceAction: 'Replace Pairing File',
      pickerTitle: 'Select your pairing file',
      imported: 'Pairing file imported successfully.',
      replaced: 'Pairing file replaced successfully.',
      invalidExtension: 'Please select a .mobiledevicepairing file.',
      invalidFile: 'The selected pairing file is empty or invalid.',
      importFailed: 'The pairing file could not be imported.',
      setupTitle: 'Pairing File for JIT',
      setupBody: 'NeoStation can use built-in StikJIT to launch MeloNX with JIT. Import this iPhone\'s .mobiledevicepairing file once. It is stored privately inside NeoStation and can be replaced later in Settings → Tools.',
      chooseFile: 'Choose Pairing File',
      later: 'Later',
      checking: 'Checking pairing file…',
      jitRequired: 'A pairing file is required for built-in JIT.',
    },
    'de': {
      title: 'Pairing-Datei',
      configured: 'Konfiguriert',
      notConfigured: 'Nicht konfiguriert',
      configuredSubtitle: 'Die Pairing-Datei ist eingerichtet. Wähle diese Option, um sie zu ersetzen.',
      notConfiguredSubtitle: 'Importiere die .mobiledevicepairing-Datei dieses iPhones für das integrierte JIT.',
      importAction: 'Pairing-Datei importieren',
      replaceAction: 'Pairing-Datei ersetzen',
      pickerTitle: 'Pairing-Datei auswählen',
      imported: 'Pairing-Datei wurde erfolgreich importiert.',
      replaced: 'Pairing-Datei wurde erfolgreich ersetzt.',
      invalidExtension: 'Bitte wähle eine .mobiledevicepairing-Datei aus.',
      invalidFile: 'Die ausgewählte Pairing-Datei ist leer oder ungültig.',
      importFailed: 'Die Pairing-Datei konnte nicht importiert werden.',
      setupTitle: 'Pairing-Datei für JIT',
      setupBody: 'NeoStation kann das integrierte StikJIT verwenden, um MeloNX mit JIT zu starten. Importiere einmal die .mobiledevicepairing-Datei dieses iPhones. Sie wird privat in NeoStation gespeichert und kann später unter Einstellungen → Werkzeuge ersetzt werden.',
      chooseFile: 'Pairing-Datei auswählen',
      later: 'Später',
      checking: 'Pairing-Datei wird geprüft…',
      jitRequired: 'Für das integrierte JIT ist eine Pairing-Datei erforderlich.',
    },
    'es': {
      title: 'Archivo de emparejamiento',
      configured: 'Configurado',
      notConfigured: 'Sin configurar',
      configuredSubtitle: 'El archivo de emparejamiento está configurado. Selecciona esta opción para reemplazarlo.',
      notConfiguredSubtitle: 'Importa el archivo .mobiledevicepairing de este iPhone para el JIT integrado.',
      importAction: 'Importar archivo de emparejamiento',
      replaceAction: 'Reemplazar archivo de emparejamiento',
      pickerTitle: 'Selecciona tu archivo de emparejamiento',
      imported: 'Archivo de emparejamiento importado correctamente.',
      replaced: 'Archivo de emparejamiento reemplazado correctamente.',
      invalidExtension: 'Selecciona un archivo .mobiledevicepairing.',
      invalidFile: 'El archivo de emparejamiento seleccionado está vacío o no es válido.',
      importFailed: 'No se pudo importar el archivo de emparejamiento.',
      setupTitle: 'Archivo de emparejamiento para JIT',
      setupBody: 'NeoStation puede usar StikJIT integrado para iniciar MeloNX con JIT. Importa una vez el archivo .mobiledevicepairing de este iPhone. Se guardará de forma privada dentro de NeoStation y podrás reemplazarlo más tarde en Ajustes → Herramientas.',
      chooseFile: 'Elegir archivo de emparejamiento',
      later: 'Más tarde',
      checking: 'Comprobando el archivo de emparejamiento…',
      jitRequired: 'Se necesita un archivo de emparejamiento para el JIT integrado.',
    },
    'fr': {
      title: 'Pairing File',
      configured: 'Configuré',
      notConfigured: 'Non configuré',
      configuredSubtitle: 'Le Pairing File est configuré. Sélectionnez cette option pour le remplacer.',
      notConfiguredSubtitle: 'Importez le fichier .mobiledevicepairing de cet iPhone pour le JIT intégré.',
      importAction: 'Importer le Pairing File',
      replaceAction: 'Remplacer le Pairing File',
      pickerTitle: 'Sélectionnez votre Pairing File',
      imported: 'Pairing File importé avec succès.',
      replaced: 'Pairing File remplacé avec succès.',
      invalidExtension: 'Veuillez sélectionner un fichier .mobiledevicepairing.',
      invalidFile: 'Le Pairing File sélectionné est vide ou invalide.',
      importFailed: 'Le Pairing File n’a pas pu être importé.',
      setupTitle: 'Pairing File pour le JIT',
      setupBody: 'NeoStation peut utiliser StikJIT intégré pour lancer MeloNX avec le JIT. Importez une seule fois le fichier .mobiledevicepairing de cet iPhone. Il sera conservé dans le stockage privé de NeoStation et pourra être remplacé plus tard dans Paramètres → Outils.',
      chooseFile: 'Choisir le Pairing File',
      later: 'Plus tard',
      checking: 'Vérification du Pairing File…',
      jitRequired: 'Un Pairing File est requis pour le JIT intégré.',
    },
    'id': {
      title: 'File Pairing',
      configured: 'Dikonfigurasi',
      notConfigured: 'Belum dikonfigurasi',
      configuredSubtitle: 'File pairing sudah dikonfigurasi. Pilih opsi ini untuk menggantinya.',
      notConfiguredSubtitle: 'Impor file .mobiledevicepairing iPhone ini untuk JIT bawaan.',
      importAction: 'Impor File Pairing',
      replaceAction: 'Ganti File Pairing',
      pickerTitle: 'Pilih file pairing Anda',
      imported: 'File pairing berhasil diimpor.',
      replaced: 'File pairing berhasil diganti.',
      invalidExtension: 'Silakan pilih file .mobiledevicepairing.',
      invalidFile: 'File pairing yang dipilih kosong atau tidak valid.',
      importFailed: 'File pairing tidak dapat diimpor.',
      setupTitle: 'File Pairing untuk JIT',
      setupBody: 'NeoStation dapat menggunakan StikJIT bawaan untuk menjalankan MeloNX dengan JIT. Impor file .mobiledevicepairing iPhone ini satu kali. File disimpan secara privat di dalam NeoStation dan dapat diganti nanti di Pengaturan → Alat.',
      chooseFile: 'Pilih File Pairing',
      later: 'Nanti',
      checking: 'Memeriksa file pairing…',
      jitRequired: 'File pairing diperlukan untuk JIT bawaan.',
    },
    'it': {
      title: 'File di abbinamento',
      configured: 'Configurato',
      notConfigured: 'Non configurato',
      configuredSubtitle: 'Il file di abbinamento è configurato. Seleziona questa opzione per sostituirlo.',
      notConfiguredSubtitle: 'Importa il file .mobiledevicepairing di questo iPhone per il JIT integrato.',
      importAction: 'Importa file di abbinamento',
      replaceAction: 'Sostituisci file di abbinamento',
      pickerTitle: 'Seleziona il file di abbinamento',
      imported: 'File di abbinamento importato correttamente.',
      replaced: 'File di abbinamento sostituito correttamente.',
      invalidExtension: 'Seleziona un file .mobiledevicepairing.',
      invalidFile: 'Il file di abbinamento selezionato è vuoto o non valido.',
      importFailed: 'Impossibile importare il file di abbinamento.',
      setupTitle: 'File di abbinamento per JIT',
      setupBody: 'NeoStation può usare StikJIT integrato per avviare MeloNX con JIT. Importa una sola volta il file .mobiledevicepairing di questo iPhone. Verrà conservato privatamente in NeoStation e potrà essere sostituito in seguito in Impostazioni → Strumenti.',
      chooseFile: 'Scegli file di abbinamento',
      later: 'Più tardi',
      checking: 'Verifica del file di abbinamento…',
      jitRequired: 'Per il JIT integrato è necessario un file di abbinamento.',
    },
    'ja': {
      title: 'ペアリングファイル',
      configured: '設定済み',
      notConfigured: '未設定',
      configuredSubtitle: 'ペアリングファイルは設定済みです。この項目から置き換えられます。',
      notConfiguredSubtitle: '内蔵JIT用に、このiPhoneの .mobiledevicepairing ファイルを読み込みます。',
      importAction: 'ペアリングファイルを読み込む',
      replaceAction: 'ペアリングファイルを置き換える',
      pickerTitle: 'ペアリングファイルを選択',
      imported: 'ペアリングファイルを読み込みました。',
      replaced: 'ペアリングファイルを置き換えました。',
      invalidExtension: '.mobiledevicepairing ファイルを選択してください。',
      invalidFile: '選択したペアリングファイルが空か、無効です。',
      importFailed: 'ペアリングファイルを読み込めませんでした。',
      setupTitle: 'JIT用ペアリングファイル',
      setupBody: 'NeoStationは内蔵StikJITを使用してMeloNXをJIT付きで起動できます。このiPhoneの .mobiledevicepairing ファイルを一度読み込んでください。ファイルはNeoStation内に非公開で保存され、後から「設定 → ツール」で置き換えられます。',
      chooseFile: 'ペアリングファイルを選択',
      later: '後で',
      checking: 'ペアリングファイルを確認中…',
      jitRequired: '内蔵JITにはペアリングファイルが必要です。',
    },
    'ko': {
      title: '페어링 파일',
      configured: '설정됨',
      notConfigured: '설정되지 않음',
      configuredSubtitle: '페어링 파일이 설정되어 있습니다. 이 옵션에서 교체할 수 있습니다.',
      notConfiguredSubtitle: '내장 JIT를 위해 이 iPhone의 .mobiledevicepairing 파일을 가져옵니다.',
      importAction: '페어링 파일 가져오기',
      replaceAction: '페어링 파일 교체',
      pickerTitle: '페어링 파일 선택',
      imported: '페어링 파일을 성공적으로 가져왔습니다.',
      replaced: '페어링 파일을 성공적으로 교체했습니다.',
      invalidExtension: '.mobiledevicepairing 파일을 선택하세요.',
      invalidFile: '선택한 페어링 파일이 비어 있거나 올바르지 않습니다.',
      importFailed: '페어링 파일을 가져올 수 없습니다.',
      setupTitle: 'JIT용 페어링 파일',
      setupBody: 'NeoStation은 내장 StikJIT를 사용해 MeloNX를 JIT와 함께 실행할 수 있습니다. 이 iPhone의 .mobiledevicepairing 파일을 한 번 가져오세요. 파일은 NeoStation 내부에 비공개로 저장되며 나중에 설정 → 도구에서 교체할 수 있습니다.',
      chooseFile: '페어링 파일 선택',
      later: '나중에',
      checking: '페어링 파일 확인 중…',
      jitRequired: '내장 JIT에는 페어링 파일이 필요합니다.',
    },
    'pt': {
      title: 'Arquivo de emparelhamento',
      configured: 'Configurado',
      notConfigured: 'Não configurado',
      configuredSubtitle: 'O arquivo de emparelhamento está configurado. Selecione esta opção para substituí-lo.',
      notConfiguredSubtitle: 'Importe o arquivo .mobiledevicepairing deste iPhone para o JIT integrado.',
      importAction: 'Importar arquivo de emparelhamento',
      replaceAction: 'Substituir arquivo de emparelhamento',
      pickerTitle: 'Selecione o arquivo de emparelhamento',
      imported: 'Arquivo de emparelhamento importado com sucesso.',
      replaced: 'Arquivo de emparelhamento substituído com sucesso.',
      invalidExtension: 'Selecione um arquivo .mobiledevicepairing.',
      invalidFile: 'O arquivo de emparelhamento selecionado está vazio ou é inválido.',
      importFailed: 'Não foi possível importar o arquivo de emparelhamento.',
      setupTitle: 'Arquivo de emparelhamento para JIT',
      setupBody: 'O NeoStation pode usar o StikJIT integrado para iniciar o MeloNX com JIT. Importe uma vez o arquivo .mobiledevicepairing deste iPhone. Ele será armazenado de forma privada no NeoStation e poderá ser substituído depois em Configurações → Ferramentas.',
      chooseFile: 'Escolher arquivo de emparelhamento',
      later: 'Mais tarde',
      checking: 'Verificando o arquivo de emparelhamento…',
      jitRequired: 'É necessário um arquivo de emparelhamento para o JIT integrado.',
    },
    'ru': {
      title: 'Файл сопряжения',
      configured: 'Настроен',
      notConfigured: 'Не настроен',
      configuredSubtitle: 'Файл сопряжения настроен. Выберите этот пункт, чтобы заменить его.',
      notConfiguredSubtitle: 'Импортируйте файл .mobiledevicepairing этого iPhone для встроенного JIT.',
      importAction: 'Импортировать файл сопряжения',
      replaceAction: 'Заменить файл сопряжения',
      pickerTitle: 'Выберите файл сопряжения',
      imported: 'Файл сопряжения успешно импортирован.',
      replaced: 'Файл сопряжения успешно заменён.',
      invalidExtension: 'Выберите файл .mobiledevicepairing.',
      invalidFile: 'Выбранный файл сопряжения пуст или недействителен.',
      importFailed: 'Не удалось импортировать файл сопряжения.',
      setupTitle: 'Файл сопряжения для JIT',
      setupBody: 'NeoStation может использовать встроенный StikJIT для запуска MeloNX с JIT. Один раз импортируйте файл .mobiledevicepairing этого iPhone. Он будет храниться приватно внутри NeoStation и позже его можно заменить в Настройки → Инструменты.',
      chooseFile: 'Выбрать файл сопряжения',
      later: 'Позже',
      checking: 'Проверка файла сопряжения…',
      jitRequired: 'Для встроенного JIT требуется файл сопряжения.',
    },
    'zh': {
      title: '配对文件',
      configured: '已配置',
      notConfigured: '未配置',
      configuredSubtitle: '配对文件已配置。选择此选项可替换文件。',
      notConfiguredSubtitle: '导入此 iPhone 的 .mobiledevicepairing 文件以使用内置 JIT。',
      importAction: '导入配对文件',
      replaceAction: '替换配对文件',
      pickerTitle: '选择配对文件',
      imported: '配对文件导入成功。',
      replaced: '配对文件替换成功。',
      invalidExtension: '请选择 .mobiledevicepairing 文件。',
      invalidFile: '所选配对文件为空或无效。',
      importFailed: '无法导入配对文件。',
      setupTitle: 'JIT 配对文件',
      setupBody: 'NeoStation 可以使用内置 StikJIT 以 JIT 方式启动 MeloNX。请一次性导入此 iPhone 的 .mobiledevicepairing 文件。文件会私密保存在 NeoStation 内，之后可在“设置 → 工具”中替换。',
      chooseFile: '选择配对文件',
      later: '稍后',
      checking: '正在检查配对文件…',
      jitRequired: '内置 JIT 需要配对文件。',
    },
    'zh_Hant': {
      title: '配對檔案',
      configured: '已設定',
      notConfigured: '未設定',
      configuredSubtitle: '配對檔案已設定。選擇此選項即可取代檔案。',
      notConfiguredSubtitle: '匯入此 iPhone 的 .mobiledevicepairing 檔案以使用內建 JIT。',
      importAction: '匯入配對檔案',
      replaceAction: '取代配對檔案',
      pickerTitle: '選擇配對檔案',
      imported: '配對檔案匯入成功。',
      replaced: '配對檔案取代成功。',
      invalidExtension: '請選擇 .mobiledevicepairing 檔案。',
      invalidFile: '所選配對檔案為空或無效。',
      importFailed: '無法匯入配對檔案。',
      setupTitle: 'JIT 配對檔案',
      setupBody: 'NeoStation 可以使用內建 StikJIT 以 JIT 啟動 MeloNX。請一次匯入此 iPhone 的 .mobiledevicepairing 檔案。檔案會私密儲存在 NeoStation 內，之後可在「設定 → 工具」中取代。',
      chooseFile: '選擇配對檔案',
      later: '稍後',
      checking: '正在檢查配對檔案…',
      jitRequired: '內建 JIT 需要配對檔案。',
    },
  };
}
