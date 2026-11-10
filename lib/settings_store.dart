import 'dart:developer';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';
import 'fake_contacts_core.dart';

const String kDefaultLastNames = "Zen,Zaragoza,Zabinski,Zimmermann,Zapata,Zona,Zidane,Zeiss,Zimmer,Zaal,Zaman,Zambrano,Zanetti,Zangari,Zappa,Zavala,Zawisza,Zeegers,Zelenka,Zellweger,Zeni,Zhang,Zhao,Zheng,Zhou,Ziegler,Zima";
const String kDefaultFirstNames = "Zoe,Zach,Zbigniew,Zaire,Zero,Zakai,Zamir,Zan,Zanna,Zareen,Zeb,Zeki,Zelda,Zella,Zeno,Zephyr,Zhen,Zhi,Zhong,Zhu,Ziba,Ziggy,Zion,Zola,Zolyan,Zora,Zsazsa,Zuzana";

/// The four settings as typed in the text fields (untrimmed).
class Settings {
  final String lastNamesText;
  final String firstNamesText;
  final String phoneTemplateText;
  final String emailTemplateText;

  const Settings({
    required this.lastNamesText,
    required this.firstNamesText,
    required this.phoneTemplateText,
    required this.emailTemplateText,
  });

  /// What a first run starts with.
  static const Settings defaults = Settings(
    lastNamesText: kDefaultLastNames,
    firstNamesText: kDefaultFirstNames,
    phoneTemplateText: kDefaultPhoneTemplate,
    emailTemplateText: kDefaultEmailTemplate,
  );

  List<String> get lastNames => parseNames(lastNamesText);
  List<String> get firstNames => parseNames(firstNamesText);
  String get phoneTemplate => phoneTemplateText.trim();
  String get emailTemplate => emailTemplateText.trim();

  Settings copyWith({String? phoneTemplateText}) => Settings(
        lastNamesText: lastNamesText,
        firstNamesText: firstNamesText,
        phoneTemplateText: phoneTemplateText ?? this.phoneTemplateText,
        emailTemplateText: emailTemplateText,
      );

  @override
  bool operator ==(Object other) =>
      other is Settings &&
      other.lastNamesText == lastNamesText &&
      other.firstNamesText == firstNamesText &&
      other.phoneTemplateText == phoneTemplateText &&
      other.emailTemplateText == emailTemplateText;

  @override
  int get hashCode => Object.hash(
      lastNamesText, firstNamesText, phoneTemplateText, emailTemplateText);

  @override
  String toString() =>
      'Settings($lastNamesText, $firstNamesText, $phoneTemplateText, $emailTemplateText)';
}

/// Keeps the [Settings] in the app's SharedPreferences.
class SettingsStore {
  static const String kLastNamesKey = 'sListOfLastNames';
  static const String kFirstNamesKey = 'sListOfFirstNames';
  static const String kPhoneTemplateKey = 'sPhoneNumberTemplate';
  static const String kEmailTemplateKey = 'sEmailAddressTemplate';

  const SettingsStore();

  /// Reads the settings, filling in [Settings.defaults] on first run and
  /// replacing the old +213 default phone template. Saves the result if
  /// either happened.
  Future<Settings> load() async {
    log("SettingsStore.load: called");
    final prefs = await SharedPreferences.getInstance();
    final String? sStoredLastNames = prefs.getString(kLastNamesKey);
    bool bNeedsSave = false;
    Settings settings;
    if (sStoredLastNames == null) {
      settings = Settings.defaults;
      bNeedsSave = true;
    } else {
      settings = Settings(
        lastNamesText: sStoredLastNames,
        firstNamesText: prefs.getString(kFirstNamesKey) ?? "",
        phoneTemplateText: prefs.getString(kPhoneTemplateKey) ?? "",
        emailTemplateText: prefs.getString(kEmailTemplateKey) ?? "",
      );
    }
    if (settings.phoneTemplateText == kLegacyDefaultPhoneTemplate) {
      // old default was in Algeria's real country code (+213)
      settings = settings.copyWith(phoneTemplateText: kDefaultPhoneTemplate);
      bNeedsSave = true;
    }
    if (bNeedsSave) await save(settings);
    return settings;
  }

  /// A failed write (Android reports it as false, e.g. with the storage
  /// full) or an error is only logged: the settings stay in memory
  /// meanwhile, and the next save tries again.
  Future<void> save(Settings settings) async {
    log("SettingsStore.save: called");
    try {
      final prefs = await SharedPreferences.getInstance();
      var bSaved = true;
      for (final (key, value) in [
        (kLastNamesKey, settings.lastNamesText),
        (kFirstNamesKey, settings.firstNamesText),
        (kPhoneTemplateKey, settings.phoneTemplateText),
        (kEmailTemplateKey, settings.emailTemplateText),
      ]) {
        if (!await prefs.setString(key, value)) bSaved = false;
      }
      if (!bSaved) {
        logError("SettingsStore.save", "Android could not write the settings");
      }
    } catch (e, st) {
      logError("SettingsStore.save", e, st);
    }
  }
}

/// Thrown when the ledger couldn't be written, e.g. with the phone's
/// storage full.
class LedgerNotSaved implements Exception {
  const LedgerNotSaved();

  @override
  String toString() => 'LedgerNotSaved: Android could not write the ledger';
}

/// Keeps the [Ledger] of created raw contacts in the app's SharedPreferences,
/// with the [PendingCreate] of a Create in progress, if any.
class LedgerStore {
  const LedgerStore();

  Future<Ledger> load() async => (await loadWithPending()).ledger;

  /// The ledger, and the [PendingCreate] saved with it, if any.
  Future<({Ledger ledger, PendingCreate? pending})> loadWithPending() async {
    final prefs = await SharedPreferences.getInstance();
    return Ledger.decodeWithPending(prefs.getString(kLedgerPrefsKey));
  }

  /// Saves [ledger] with [pending], in one write; without [pending], one
  /// saved earlier is dropped.
  ///
  /// Throws [LedgerNotSaved] if it couldn't be written. (Until the app is
  /// restarted, [load] then still returns it: the plugin keeps it in memory
  /// either way.)
  Future<void> save(Ledger ledger, {PendingCreate? pending}) async {
    final prefs = await SharedPreferences.getInstance();
    // Android reports a failed write as false rather than as an error.
    if (!await prefs.setString(
        kLedgerPrefsKey, ledger.encode(pending: pending))) {
      throw const LedgerNotSaved();
    }
  }
}
