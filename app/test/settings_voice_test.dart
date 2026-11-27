import 'package:audiobook_reader/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await SettingsService.load();
  });

  test('a book with no voice of its own uses the last voice picked', () async {
    expect(settings.voiceFor('a'), isNull);
    await settings.setVoice('en_GB-alba-medium');
    expect(settings.voiceFor('a'), 'en_GB-alba-medium');
  });

  test('a voice chosen in one book stays with that book', () async {
    await settings.setVoiceFor('novel', 'en_US-ryan-high');
    await settings.setVoiceFor('textbook', 'en_GB-alba-medium');
    expect(settings.voiceFor('novel'), 'en_US-ryan-high');
    expect(settings.voiceFor('textbook'), 'en_GB-alba-medium');
    // ...and becomes the default for a book never set up.
    expect(settings.voiceFor('new'), 'en_GB-alba-medium');
  });

  test('rate is per book, null until changed, and clamped', () async {
    expect(settings.rateFor('a'), isNull);
    await settings.setRateFor('a', 0.75);
    await settings.setRateFor('b', 5);
    expect(settings.rateFor('a'), 0.75);
    expect(settings.rateFor('b'), 1.0);
    expect(settings.rateFor('c'), isNull);
  });

  test('pronunciations persist as typed and parse to rules', () async {
    await settings.setPronunciationsText('# names\nHermione = her-my-oh-nee');
    expect(settings.pronunciationsText, '# names\nHermione = her-my-oh-nee');
    expect(settings.pronunciations, {'Hermione': 'her-my-oh-nee'});
  });
}
