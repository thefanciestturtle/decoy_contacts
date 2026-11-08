import 'package:flutter_test/flutter_test.dart';

import 'package:fake_contacts/fake_contacts_core.dart';

void main() {
  group('parseNames', () {
    test('trims, drops empties and duplicates', () {
      expect(parseNames(' Zen, Zima ,,Zen,'), ['Zen', 'Zima']);
      expect(parseNames(''), isEmpty);
    });
  });

  group('generatePhoneNumber', () {
    test('default template stays in the Ofcom drama range', () {
      final n = generatePhoneNumber(kDefaultPhoneTemplate, 'Zaragoza');
      expect(n, matches(RegExp(r'^\+447700900\d{3}$')));
    });

    test('is deterministic and pads short names with 0', () {
      // 'Z' = 90, 'e' = 101, 'n' = 110 -> 0, 1, 0
      expect(generatePhoneNumber('+1nnnn', 'Zen'), '+10100');
      expect(generatePhoneNumber('+1nnnn', 'Zen'), '+10100');
    });

    test('legacy default was in a real country code', () {
      expect(kLegacyDefaultPhoneTemplate.startsWith('+213'), isTrue);
      expect(kDefaultPhoneTemplate, isNot(kLegacyDefaultPhoneTemplate));
    });
  });

  test('generateEmailAddress fills FIRST and LAST', () {
    expect(generateEmailAddress(kDefaultEmailTemplate, 'Zoe', 'Zen'),
        'Zoe.Zen@example.com');
  });

  test('allCombinations covers every pair', () {
    final c = allCombinations(['Zoe', 'Zach'], ['Zen', 'Zima', 'Zhou']);
    expect(c, hasLength(6));
    expect(c.toSet(), hasLength(6));
    expect(c.first.displayName, 'Zoe Zen');
  });

  group('Ledger', () {
    test('round-trips through JSON', () {
      final l = Ledger({'10': 'Zoe Zen', '11': 'Zach Zen'});
      expect(Ledger.decode(l.encode()).rawIdToName, l.rawIdToName);
    });

    test('decodes missing or corrupt data as empty', () {
      expect(Ledger.decode(null).isEmpty, isTrue);
      expect(Ledger.decode('not json').isEmpty, isTrue);
      expect(Ledger.decode('[1,2]').isEmpty, isTrue);
    });

    test('prunes raw contacts that no longer exist', () {
      final l = Ledger({'10': 'Zoe Zen', '11': 'Zach Zen'});
      expect(l.prunedTo({'11'}).rawIdToName, {'11': 'Zach Zen'});
    });
  });

  group('namesToCreate', () {
    final wanted = allCombinations(['Zoe', 'Zach'], ['Zen']);

    test('creates everything on first run', () {
      expect(namesToCreate(wanted, Ledger(), {}), wanted);
    });

    test('skips fakes that already exist', () {
      final ledger = Ledger({'10': 'Zoe Zen'});
      final book = {'c10': ['10']};
      expect(namesToCreate(wanted, ledger, book), [const FakeName('Zach', 'Zen')]);
    });

    test('re-creates a tracked fake the user deleted', () {
      final ledger = Ledger({'10': 'Zoe Zen'});
      expect(namesToCreate(wanted, ledger, {}), wanted);
    });

    test('a real contact with the same name does not count as existing', () {
      final book = {'c1': ['1']}; // real "Zoe Zen", not in ledger
      expect(namesToCreate(wanted, Ledger(), book), wanted);
    });

    String fp(FakeName n) => contactFingerprint(
        n.displayName,
        generatePhoneNumber(kDefaultPhoneTemplate, n.last),
        generateEmailAddress(kDefaultEmailTemplate, n.first, n.last));

    test('skips an untracked contact identical to the fake (lost ledger)', () {
      // Same name, number and email as the fake would get, but not in the
      // ledger, e.g. after the app's data was cleared.
      final zoe = const FakeName('Zoe', 'Zen');
      final existing = fingerprintsOf(
        'Zoe Zen',
        [generatePhoneNumber(kDefaultPhoneTemplate, 'Zen')],
        ['ZOE.ZEN@example.com', 'other@example.org'],
      ).toSet();
      expect(
        namesToCreate(wanted, Ledger(), {'c9': ['9']},
            existingFingerprints: existing, fingerprintOf: fp),
        [const FakeName('Zach', 'Zen')],
      );
      expect(fp(zoe), isIn(existing));
    });

    test('a real contact with the same name but other details is not skipped', () {
      final existing =
          fingerprintsOf('Zoe Zen', ['+1 555 555 0101'], []).toSet();
      expect(
        namesToCreate(wanted, Ledger(), {'c1': ['1']},
            existingFingerprints: existing, fingerprintOf: fp),
        wanted,
      );
    });
  });

  test('contactFingerprint ignores phone formatting and email case', () {
    expect(contactFingerprint('A B', '+44 7700-900 015', 'A.B@Example.com'),
        contactFingerprint('A B', '+447700900015', 'a.b@example.com'));
  });

  group('newlyCreatedRawIds', () {
    test('records only raw contacts that did not exist before', () {
      final created = [const FakeName('Zoe', 'Zen'), const FakeName('Zach', 'Zen')];
      final before = {'c1': ['1']}; // real Zoe Zen
      // Android merged the new fake Zoe Zen (raw 20) into the real contact c1.
      final after = {'c1': ['1', '20'], 'c21': ['21']};
      expect(
        newlyCreatedRawIds(
            created: created,
            createdContactIds: ['c1', 'c21'],
            before: before,
            after: after),
        {'20': 'Zoe Zen', '21': 'Zach Zen'},
      );
    });
  });

  group('planDelete', () {
    test('deletes contacts made only of tracked fakes', () {
      final ledger = Ledger({'20': 'Zoe Zen', '21': 'Zach Zen'});
      final book = {
        'c20': ['20'],
        'c21': ['21'],
        'c1': ['1'], // real contact
      };
      final plan = planDelete(ledger, book);
      expect(plan.contactIdsToDelete, unorderedEquals(['c20', 'c21']));
      expect(plan.rawContactsDeleted, 2);
      expect(plan.skippedMerged, 0);
      expect(plan.remaining.isEmpty, isTrue);
    });

    test('never deletes a real contact with the same name as a fake', () {
      // Real "Zoe Zen" (raw 1) and fake "Zoe Zen" (raw 20) as separate contacts.
      final ledger = Ledger({'20': 'Zoe Zen'});
      final book = {'c1': ['1'], 'c20': ['20']};
      final plan = planDelete(ledger, book);
      expect(plan.contactIdsToDelete, ['c20']);
    });

    test('leaves a fake alone if Android merged it with a real contact', () {
      final ledger = Ledger({'20': 'Zoe Zen'});
      final book = {'c1': ['1', '20']};
      final plan = planDelete(ledger, book);
      expect(plan.contactIdsToDelete, isEmpty);
      expect(plan.skippedMerged, 1);
      expect(plan.remaining.rawIdToName, {'20': 'Zoe Zen'});
    });

    test('with an empty ledger deletes nothing', () {
      final plan = planDelete(Ledger(), {'c1': ['1'], 'c2': ['2']});
      expect(plan.contactIdsToDelete, isEmpty);
    });
  });
}
