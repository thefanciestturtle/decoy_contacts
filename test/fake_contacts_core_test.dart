import 'package:flutter_test/flutter_test.dart';

import 'package:fake_contacts/fake_contacts_core.dart';

/// The ledger entry for a fake made with the default templates.
LedgerEntry fake(String first, String last) =>
    entryFor(FakeName(first, last), kDefaultPhoneTemplate, kDefaultEmailTemplate);

/// Fingerprints of a contact holding exactly what [e] recorded.
Set<String> fingerprintsMatching(LedgerEntry e) => fingerprintsOf(e.name,
    [if (e.phone!.isNotEmpty) e.phone!], [if (e.email!.isNotEmpty) e.email!]).toSet();

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

  group('entryFor', () {
    test('records the phone and email the fake gets', () {
      final e = fake('Zoe', 'Zen');
      expect(e.name, 'Zoe Zen');
      expect(e.phone, generatePhoneNumber(kDefaultPhoneTemplate, 'Zen'));
      expect(e.email, 'Zoe.Zen@example.com');
      expect(e.fingerprint, contactFingerprint('Zoe Zen', e.phone!, e.email!));
    });

    test('empty templates give no phone or email', () {
      final e = entryFor(const FakeName('Zoe', 'Zen'), '', '');
      expect(e.phone, '');
      expect(e.email, '');
      expect(e.fingerprint, isNotNull);
    });
  });

  group('Ledger', () {
    test('round-trips through JSON', () {
      final l = Ledger({'10': fake('Zoe', 'Zen'), '11': fake('Zach', 'Zen')});
      expect(Ledger.decode(l.encode()).entries, l.entries);
    });

    test('reads the old format, which stored only names', () {
      final l = Ledger.decode('{"10":"Zoe Zen","11":"Zach Zen"}');
      expect(l.entries, {
        '10': const LedgerEntry.nameOnly('Zoe Zen'),
        '11': const LedgerEntry.nameOnly('Zach Zen'),
      });
      expect(l.entries['10']!.hasDetails, isFalse);
      expect(l.entries['10']!.fingerprint, isNull);
    });

    test('decodes missing or corrupt data as empty', () {
      expect(Ledger.decode(null).isEmpty, isTrue);
      expect(Ledger.decode('not json').isEmpty, isTrue);
      expect(Ledger.decode('[1,2]').isEmpty, isTrue);
      expect(Ledger.decode('{"10":5,"11":{"phone":"1"}}').isEmpty, isTrue);
    });

    test('prunes raw contacts that no longer exist', () {
      final l = Ledger({'10': fake('Zoe', 'Zen'), '11': fake('Zach', 'Zen')});
      expect(l.prunedTo({'11'}).entries, {'11': fake('Zach', 'Zen')});
    });

    test('fills in name-only entries it has details for', () {
      final l = Ledger({
        '10': const LedgerEntry.nameOnly('Zoe Zen'),
        '11': const LedgerEntry.nameOnly('Someone Else'),
        '12': fake('Zach', 'Zen'),
      }).withDetailsForNameOnly(
          (name) => name == 'Zoe Zen' ? fake('Zoe', 'Zen') : null);
      expect(l.entries, {
        '10': fake('Zoe', 'Zen'),
        '11': const LedgerEntry.nameOnly('Someone Else'),
        '12': fake('Zach', 'Zen'),
      });
    });
  });

  group('namesToCreate', () {
    final wanted = allCombinations(['Zoe', 'Zach'], ['Zen']);

    test('creates everything on first run', () {
      expect(namesToCreate(wanted, Ledger(), {}), wanted);
    });

    test('skips fakes that already exist', () {
      final ledger = Ledger({'10': fake('Zoe', 'Zen')});
      final book = {'c10': ['10']};
      expect(namesToCreate(wanted, ledger, book), [const FakeName('Zach', 'Zen')]);
    });

    test('re-creates a tracked fake the user deleted', () {
      final ledger = Ledger({'10': fake('Zoe', 'Zen')});
      expect(namesToCreate(wanted, ledger, {}), wanted);
    });

    test('a real contact with the same name does not count as existing', () {
      final book = {'c1': ['1']}; // real "Zoe Zen", not in ledger
      expect(namesToCreate(wanted, Ledger(), book), wanted);
    });

    String fp(FakeName n) => fake(n.first, n.last).fingerprint!;

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
      final created = [fake('Zoe', 'Zen'), fake('Zach', 'Zen')];
      final before = {'c1': ['1']}; // real Zoe Zen
      // Android merged the new fake Zoe Zen (raw 20) into the real contact c1.
      final after = {'c1': ['1', '20'], 'c21': ['21']};
      expect(
        newlyCreatedRawIds(
            created: created,
            createdContactIds: ['c1', 'c21'],
            before: before,
            after: after),
        {'20': fake('Zoe', 'Zen'), '21': fake('Zach', 'Zen')},
      );
    });
  });

  group('planDelete', () {
    final zoe = fake('Zoe', 'Zen');
    final zach = fake('Zach', 'Zen');

    test('deletes contacts made only of tracked, unchanged fakes', () {
      final ledger = Ledger({'20': zoe, '21': zach});
      final book = {
        'c20': ['20'],
        'c21': ['21'],
        'c1': ['1'], // real contact
      };
      final fps = {
        'c20': fingerprintsMatching(zoe),
        'c21': fingerprintsMatching(zach),
        'c1': fingerprintsOf('Alice Example', ['+15555550103'], []).toSet(),
      };
      final plan = planDelete(ledger, book, fps);
      expect(plan.contactIdsToDelete, unorderedEquals(['c20', 'c21']));
      expect(plan.rawContactsDeleted, 2);
      expect(plan.skippedMerged, 0);
      expect(plan.skippedChanged, 0);
      expect(plan.remaining.isEmpty, isTrue);
    });

    test('deletes a fake made without phone or email', () {
      final bare = entryFor(const FakeName('Zoe', 'Zen'), '', '');
      final plan = planDelete(Ledger({'20': bare}), {'c20': ['20']},
          {'c20': fingerprintsOf('Zoe Zen', [], []).toSet()});
      expect(plan.contactIdsToDelete, ['c20']);
    });

    test('never deletes a real contact with the same name as a fake', () {
      // Real "Zoe Zen" (raw 1) and fake "Zoe Zen" (raw 20) as separate contacts.
      final ledger = Ledger({'20': zoe});
      final book = {'c1': ['1'], 'c20': ['20']};
      final fps = {
        'c1': fingerprintsOf('Zoe Zen', ['+15555550101'], []).toSet(),
        'c20': fingerprintsMatching(zoe),
      };
      final plan = planDelete(ledger, book, fps);
      expect(plan.contactIdsToDelete, ['c20']);
    });

    test('leaves a fake alone if Android merged it with a real contact', () {
      final ledger = Ledger({'20': zoe});
      final book = {'c1': ['1', '20']};
      final plan = planDelete(ledger, book, {'c1': fingerprintsMatching(zoe)});
      expect(plan.contactIdsToDelete, isEmpty);
      expect(plan.skippedMerged, 1);
      expect(plan.remaining.entries, {'20': zoe});
    });

    test('with an empty ledger deletes nothing', () {
      final plan = planDelete(Ledger(), {'c1': ['1'], 'c2': ['2']}, {});
      expect(plan.contactIdsToDelete, isEmpty);
    });

    group('a recorded raw contact ID that now holds a different contact', () {
      // E.g. the ledger was restored onto another phone, where raw contact
      // 20 is a real contact.
      void expectLeftAlone(Set<String> realFingerprints) {
        final ledger = Ledger({'20': zoe});
        final plan =
            planDelete(ledger, {'c7': ['20']}, {'c7': realFingerprints});
        expect(plan.contactIdsToDelete, isEmpty);
        expect(plan.rawContactsDeleted, 0);
        expect(plan.skippedChanged, 1);
        expect(plan.skippedMerged, 0);
        expect(plan.remaining.entries, {'20': zoe});
      }

      test('is not deleted if the name differs', () {
        expectLeftAlone(fingerprintsOf(
            'Alice Example', [zoe.phone!], [zoe.email!]).toSet());
      });

      test('is not deleted if the phone number differs', () {
        expectLeftAlone(
            fingerprintsOf('Zoe Zen', ['+15555550101'], [zoe.email!]).toSet());
      });

      test('is not deleted if the email differs', () {
        expectLeftAlone(fingerprintsOf(
            'Zoe Zen', [zoe.phone!], ['zoe@example.org']).toSet());
      });

      test('is not deleted if it has extra numbers or addresses', () {
        expectLeftAlone(fingerprintsOf('Zoe Zen',
            [zoe.phone!, '+15555550101'], [zoe.email!]).toSet());
        expectLeftAlone(fingerprintsOf('Zoe Zen', [zoe.phone!],
            [zoe.email!, 'zoe@example.org']).toSet());
      });

      test('is not deleted if it has no phone or email', () {
        expectLeftAlone(fingerprintsOf('Zoe Zen', [], []).toSet());
      });

      test('is not deleted if its details are unknown', () {
        final plan = planDelete(Ledger({'20': zoe}), {'c7': ['20']}, {});
        expect(plan.contactIdsToDelete, isEmpty);
        expect(plan.skippedChanged, 1);
      });

      test('only that contact is left alone; matching fakes are deleted', () {
        final ledger = Ledger({'20': zoe, '21': zach});
        final plan = planDelete(ledger, {
          'c7': ['20'],
          'c21': ['21'],
        }, {
          'c7': fingerprintsOf('Alice Example', ['+15555550103'], []).toSet(),
          'c21': fingerprintsMatching(zach),
        });
        expect(plan.contactIdsToDelete, ['c21']);
        expect(plan.rawContactsDeleted, 1);
        expect(plan.skippedChanged, 1);
        expect(plan.remaining.entries, {'20': zoe});
      });
    });

    test('a contact made of two tracked fakes must match both', () {
      final ledger = Ledger({'20': zoe, '21': zach});
      final book = {'c20': ['20', '21']};
      // Android shows one name for the merged contact, so Zach's fingerprint
      // can't match and nothing is deleted.
      final fps = {
        'c20': fingerprintsOf('Zoe Zen', [zoe.phone!], [zoe.email!, zach.email!])
            .toSet(),
      };
      final plan = planDelete(ledger, book, fps);
      expect(plan.contactIdsToDelete, isEmpty);
      expect(plan.skippedChanged, 2);
    });

    test('a name-only entry from an older version is never deleted as is', () {
      final ledger = Ledger({'20': const LedgerEntry.nameOnly('Zoe Zen')});
      final plan = planDelete(
          ledger, {'c20': ['20']}, {'c20': fingerprintsMatching(zoe)});
      expect(plan.contactIdsToDelete, isEmpty);
      expect(plan.skippedChanged, 1);
    });

    test('a name-only entry is deleted once filled in, if it matches', () {
      final legacy = Ledger({
        '20': const LedgerEntry.nameOnly('Zoe Zen'),
        '7': const LedgerEntry.nameOnly('Zoe Zen'),
      });
      final ledger = legacy.withDetailsForNameOnly(
          (name) => name == 'Zoe Zen' ? zoe : null);
      final plan = planDelete(ledger, {
        'c20': ['20'],
        'c7': ['7'],
      }, {
        'c20': fingerprintsMatching(zoe),
        // A real Zoe Zen at a raw ID restored from another phone.
        'c7': fingerprintsOf('Zoe Zen', ['+15555550101'], []).toSet(),
      });
      expect(plan.contactIdsToDelete, ['c20']);
      expect(plan.skippedChanged, 1);
    });
  });
}
