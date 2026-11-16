import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:decoy_contacts/fake_contacts_core.dart';

/// The ledger entry for a fake made with the default templates.
LedgerEntry fake(String first, String last) =>
    entryFor(FakeName(first, last), kDefaultPhoneTemplate, kDefaultEmailTemplate);

/// Fingerprints of a contact holding exactly what [e] recorded.
Set<String> fingerprintsMatching(LedgerEntry e) => fingerprintsOf(e.name,
    [if (e.phone.isNotEmpty) e.phone], [if (e.email.isNotEmpty) e.email]).toSet();

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
  });

  test('generateEmailAddress leaves FIRST or LAST inside a name alone', () {
    expect(generateEmailAddress(kDefaultEmailTemplate, 'BLAST', 'Zen'),
        'BLAST.Zen@example.com');
    expect(generateEmailAddress('LAST.FIRST@example.com', 'Zoe', 'FIRSTON'),
        'FIRSTON.Zoe@example.com');
    expect(generateEmailAddress('FIRSTLAST@example.com', 'Zoe', 'Zen'),
        'ZoeZen@example.com');
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

  test('firstCombination is the first of allCombinations', () {
    for (final (first, last) in [
      (['Zoe', 'Zach'], ['Zen', 'Zima', 'Zhou']),
      (['Zach'], ['Zima', 'Zen']),
      (['Zoe'], ['Zen']),
    ]) {
      expect(firstCombination(first, last), allCombinations(first, last).first);
    }
    expect(firstCombination([], ['Zen']), isNull);
    expect(firstCombination(['Zoe'], []), isNull);
  });

  group('entryFor', () {
    test('records the phone and email the fake gets', () {
      final e = fake('Zoe', 'Zen');
      expect(e.name, 'Zoe Zen');
      expect(e.phone, generatePhoneNumber(kDefaultPhoneTemplate, 'Zen'));
      expect(e.email, 'Zoe.Zen@example.com');
      expect(e.fingerprint, contactFingerprint('Zoe Zen', e.phone, e.email));
    });

    test('empty templates give no phone or email', () {
      final e = entryFor(const FakeName('Zoe', 'Zen'), '', '');
      expect(e.phone, '');
      expect(e.email, '');
      expect(e.fingerprint, contactFingerprint('Zoe Zen', '', ''));
    });
  });

  group('Ledger', () {
    test('round-trips through JSON', () {
      final l = Ledger({'10': fake('Zoe', 'Zen'), '11': fake('Zach', 'Zen')});
      expect(Ledger.decode(l.encode()).entries, l.entries);
    });

    test("drops entries it can't read, such as name-only ones, and keeps "
        'the rest', () {
      final l = Ledger.decode(jsonEncode({
        // Only a name, as early test builds stored them, in both forms.
        '10': 'Zoe Zen',
        '11': {'name': 'Zach Zen', 'phone': null, 'email': null},
        // A detail missing, or not a string.
        '12': {'name': 'Zoe Zima', 'phone': '+1'},
        '13': {'name': 'Zach Zima', 'phone': 1, 'email': ''},
        '14': {'phone': '+1', 'email': ''},
        '15': fake('Zoe', 'Zen').toJson(),
        // Extra fields are ignored.
        '16': {...fake('Zach', 'Zen').toJson() as Map, 'note': 1},
      }));
      expect(l.entries, {'15': fake('Zoe', 'Zen'), '16': fake('Zach', 'Zen')});
      // So the next save leaves them out.
      expect(jsonDecode(l.encode()), {
        '15': fake('Zoe', 'Zen').toJson(),
        '16': fake('Zach', 'Zen').toJson(),
      });
    });

    test('decodes missing or corrupt data as empty', () {
      expect(Ledger.decode(null).isEmpty, isTrue);
      expect(Ledger.decode('not json').isEmpty, isTrue);
      expect(Ledger.decode('[1,2]').isEmpty, isTrue);
      expect(Ledger.decode('{"10":5,"11":{"phone":"1"}}').isEmpty, isTrue);
    });

    test('keeps a pending Create with it, which only decodeWithPending '
        'reads', () {
      final l = Ledger({'10': fake('Zoe', 'Zen')});
      final pending = PendingCreate(
          maxRawId: 10, entries: [fake('Zach', 'Zen'), fake('Zoe', 'Zima')]);
      final json = l.encode(pending: pending);

      // It isn't taken for a ledger entry.
      expect(Ledger.decode(json).entries, l.entries);
      final decoded = Ledger.decodeWithPending(json);
      expect(decoded.ledger.entries, l.entries);
      expect(decoded.pending!.maxRawId, 10);
      expect(decoded.pending!.entries, pending.entries);
      // Without one, there is none.
      expect(Ledger.decodeWithPending(l.encode()).pending, isNull);
      expect(Ledger.decodeWithPending(null).pending, isNull);
    });

    test('a pending Create with an empty address book before it, or odd '
        'data', () {
      final json = Ledger().encode(
          pending: PendingCreate(maxRawId: null, entries: [fake('Zoe', 'Zen')]));
      final pending = Ledger.decodeWithPending(json).pending!;
      expect(pending.maxRawId, isNull);
      expect(pending.entries, [fake('Zoe', 'Zen')]);

      // Entries it can't read are dropped.
      expect(
          PendingCreate.fromJson({
            'maxRawId': 'x',
            'entries': [
              'Zoe Zen',
              {'name': 'Zoe Zima', 'phone': null, 'email': null},
              fake('Zach', 'Zen').toJson(),
              5,
            ],
          })!
              .entries,
          [fake('Zach', 'Zen')]);
      expect(PendingCreate.fromJson({'maxRawId': 3}), isNull);
      expect(PendingCreate.fromJson('x'), isNull);
    });

    test('prunes raw contacts that no longer exist', () {
      final l = Ledger({'10': fake('Zoe', 'Zen'), '11': fake('Zach', 'Zen')});
      expect(l.prunedTo({'11'}).entries, {'11': fake('Zach', 'Zen')});
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

    String fp(FakeName n) => fake(n.first, n.last).fingerprint;

    test('skips an untracked contact identical to the fake (lost ledger)', () {
      // Same name, number and email as the fake would get, but not in the
      // ledger, e.g. after the app's data was cleared.
      const zoe = FakeName('Zoe', 'Zen');
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
    final zoe = fake('Zoe', 'Zen');
    final zach = fake('Zach', 'Zen');
    // Each other's names in another order: Android merges them, as they
    // share a phone number.
    final zenaZen = fake('Zena', 'Zen');
    final zenZena = fake('Zen', 'Zena');

    test('records only raw contacts that did not exist before', () {
      final before = {'c1': ['1']}; // real Zoe Zen
      // Android merged the new fake Zoe Zen (raw 20) into the real contact
      // c1. One new raw contact in the contact the call gave for a fake is
      // that fake, whatever its details.
      final after = {'c1': ['1', '20'], 'c21': ['21']};
      expect(
        newlyCreatedRawIds(
            created: [zoe, zach],
            createdContactIds: ['c1', 'c21'],
            oldRawIds: allRawIds(before),
            after: after,
            fingerprintsByRaw: const {}),
        {'20': zoe, '21': zach},
      );
    });

    test('tells apart fakes that Android merged with each other by their '
        'own details', () {
      // The call gives the merged contact's ID for both. Raw 22 is the
      // second fake, raw 23 the first.
      expect(
        newlyCreatedRawIds(
            created: [zenaZen, zenZena, zoe],
            createdContactIds: ['c22', 'c22', 'c24'],
            oldRawIds: const {},
            after: {'c22': ['22', '23'], 'c24': ['24']},
            fingerprintsByRaw: {
              '22': fingerprintsMatching(zenZena),
              '23': fingerprintsMatching(zenaZen),
              '24': fingerprintsMatching(zoe),
            }),
        {'22': zenZena, '23': zenaZen, '24': zoe},
      );
    });

    test('finds a fake that Android moved into the contact the call gave for '
        'another', () {
      // The contact ID given for "Zena Zen" is gone: Android moved its raw
      // contact, 22, into the contact of "Zen Zena".
      expect(
        newlyCreatedRawIds(
            created: [zenaZen, zenZena],
            createdContactIds: ['c22', 'c23'],
            oldRawIds: const {},
            after: {'c23': ['22', '23']},
            fingerprintsByRaw: {
              '22': fingerprintsMatching(zenaZen),
              '23': fingerprintsMatching(zenZena),
            }),
        {'22': zenaZen, '23': zenZena},
      );
    });

    test('leaves out a merged fake whose details it can\'t find', () {
      // Raw 23 was changed meanwhile (or its details couldn't be read).
      expect(
        newlyCreatedRawIds(
            created: [zenaZen, zenZena],
            createdContactIds: ['c22', 'c22'],
            oldRawIds: const {},
            after: {'c22': ['22', '23']},
            fingerprintsByRaw: {'22': fingerprintsMatching(zenaZen)}),
        {'22': zenaZen},
      );
    });

    test('a raw contact added meanwhile in the same contact is not taken '
        'for the fake', () {
      // Raw 30, a Zoe Zen with another number, came in (say, synced) while
      // the fake was created, and Android merged them.
      final other = fingerprintsOf('Zoe Zen', ['+15555550101'], []).toSet();
      expect(
        newlyCreatedRawIds(
            created: [zoe],
            createdContactIds: ['c20'],
            oldRawIds: const {},
            after: {'c20': ['20', '30']},
            fingerprintsByRaw: {'20': fingerprintsMatching(zoe), '30': other}),
        {'20': zoe},
      );
      // A copy with the fake's very details: which one is the fake can't be
      // told.
      expect(
        newlyCreatedRawIds(
            created: [zoe],
            createdContactIds: ['c20'],
            oldRawIds: const {},
            after: {'c20': ['20', '30']},
            fingerprintsByRaw: {
              '20': fingerprintsMatching(zoe),
              '30': fingerprintsMatching(zoe),
            }),
        isEmpty,
      );
    });
  });

  group('createdBeforeFailure', () {
    final zoe = fake('Zoe', 'Zen');
    final zach = fake('Zach', 'Zen');
    final zima = fake('Zoe', 'Zima');
    final aliceFps =
        fingerprintsOf('Alice Example', ['+15555550103'], []).toSet();

    test('records the planned fakes that were created', () {
      // Zoe Zen and Zach Zen were created before it failed; Zoe Zima wasn't.
      final before = {'c1': ['1']}; // Alice
      final after = {'c1': ['1'], 'c20': ['20'], 'c21': ['21']};
      expect(
        createdBeforeFailure(
          planned: [zoe, zach, zima],
          oldRawIds: allRawIds(before),
          after: after,
          fingerprintsByRaw: {
            '1': aliceFps,
            '20': fingerprintsMatching(zoe),
            '21': fingerprintsMatching(zach),
          },
        ),
        {'20': zoe, '21': zach},
      );
    });

    test('records a fake merged into an existing contact', () {
      // A real Zoe Zen with another number; Android merged the new fake in.
      final realZoe = fingerprintsOf('Zoe Zen', ['+15555550101'], []).toSet();
      expect(
        createdBeforeFailure(
          planned: [zoe],
          oldRawIds: {'1'},
          after: {'c1': ['1', '20']},
          fingerprintsByRaw: {'1': realZoe, '20': fingerprintsMatching(zoe)},
        ),
        {'20': zoe},
      );
    });

    test('records each of two fakes merged into one contact', () {
      expect(
        createdBeforeFailure(
          planned: [zoe, zach],
          oldRawIds: const {},
          after: {'c20': ['20', '21']},
          fingerprintsByRaw: {
            '20': fingerprintsMatching(zach),
            '21': fingerprintsMatching(zoe),
          },
        ),
        {'20': zach, '21': zoe},
      );
    });

    test('never records a contact that existed before', () {
      // A contact with exactly a fake's details, which was there already
      // (in practice Create wouldn't plan that fake).
      expect(
        createdBeforeFailure(
          planned: [zoe],
          oldRawIds: {'1'},
          after: {'c1': ['1']},
          fingerprintsByRaw: {'1': fingerprintsMatching(zoe)},
        ),
        isEmpty,
      );
    });

    test('never records a new contact with other details', () {
      // Added meanwhile, e.g. synced: a Zoe Zen with another number, and
      // someone else.
      expect(
        createdBeforeFailure(
          planned: [zoe],
          oldRawIds: const {},
          after: {'c30': ['30'], 'c31': ['31']},
          fingerprintsByRaw: {
            '30': fingerprintsOf('Zoe Zen', ['+15555550101'], []).toSet(),
            '31': aliceFps,
          },
        ),
        isEmpty,
      );
    });

    test('records nothing for a fake that two new contacts match', () {
      // The fake and, say, a copy of it synced from another phone: which
      // one this app created can't be told.
      expect(
        createdBeforeFailure(
          planned: [zoe, zach],
          oldRawIds: const {},
          after: {'c20': ['20'], 'c30': ['30'], 'c21': ['21']},
          fingerprintsByRaw: {
            '20': fingerprintsMatching(zoe),
            '30': fingerprintsMatching(zoe),
            '21': fingerprintsMatching(zach),
          },
        ),
        {'21': zach},
      );
    });

    test('records nothing for a fake whose copy Android merged into its '
        'contact', () {
      expect(
        createdBeforeFailure(
          planned: [zoe],
          oldRawIds: const {},
          after: {'c20': ['20', '30']},
          fingerprintsByRaw: {
            '20': fingerprintsMatching(zoe),
            '30': fingerprintsMatching(zoe),
          },
        ),
        isEmpty,
      );
    });

    group('two planned fakes with the same name, phone and email', () {
      // Names can hold spaces: "A B" "C" and "A" "B C" are both "A B C",
      // and with templates that give no n or FIRST/LAST, the same details.
      final abc = entryFor(const FakeName('A B', 'C'), '+447700900123', '');
      Map<String, LedgerEntry> recorded(List<String> raws,
              {bool allCreated = false}) =>
          createdBeforeFailure(
            planned: [abc, abc, zoe],
            oldRawIds: const {},
            after: {'c20': raws},
            fingerprintsByRaw: {
              for (final r in raws) r: fingerprintsMatching(abc),
            },
            allCreated: allCreated,
          );

      test('if the call made them all, each raw contact with those details '
          'is recorded, up to two', () {
        expect(recorded(['20', '21'], allCreated: true),
            {'20': abc, '21': abc});
        expect(recorded(['20'], allCreated: true), {'20': abc});
        expect(recorded(['20', '21', '22'], allCreated: true), isEmpty);
      });

      test('after a failure, one is recorded only if it is the only one: a '
          'second could be a copy synced meanwhile', () {
        expect(recorded(['20']), {'20': abc});
        expect(recorded(['20', '21']), isEmpty);
      });
    });

    test('a raw contact that matches two fakes makes both ambiguous', () {
      // Raw 20 has the details of both; raw 21 only Zoe's. Either could be
      // the Zoe Zen this app created.
      expect(
        createdBeforeFailure(
          planned: [zoe, zach],
          oldRawIds: const {},
          after: {'c20': ['20'], 'c21': ['21']},
          fingerprintsByRaw: {
            '20': {...fingerprintsMatching(zoe), ...fingerprintsMatching(zach)},
            '21': fingerprintsMatching(zoe),
          },
        ),
        isEmpty,
      );
    });
  });

  test('entriesNotFound counts equal entries one by one', () {
    final zoe = fake('Zoe', 'Zen');
    final zach = fake('Zach', 'Zen');
    expect(entriesNotFound([zoe, zoe, zach], [zoe]), [zoe, zach]);
    expect(entriesNotFound([zoe, zoe, zach], [zoe, zach, zoe]), isEmpty);
    expect(entriesNotFound([zoe], []), [zoe]);
  });

  test('maxRawIdOf compares numbers, not text, and skips the rest', () {
    expect(maxRawIdOf(['9', '10', '2']), 10);
    expect(maxRawIdOf(['x', '7']), 7);
    expect(maxRawIdOf(const []), isNull);
    expect(maxRawIdOf(['x']), isNull);
  });

  group('createdByPending', () {
    final zoe = fake('Zoe', 'Zen');
    final zach = fake('Zach', 'Zen');
    final realZoe = fingerprintsOf('Zoe Zen', ['+15555550101'], []).toSet();

    test('records the pending fakes with raw IDs newer than before it',
        () {
      // Raw 1 is real, 5 a recorded fake; 6 and 7 were made by the pending
      // call; Zach's twin, raw 4, was there before (not newer).
      expect(
        createdByPending(
          PendingCreate(maxRawId: 5, entries: [zoe, zach]),
          recorded: {'5'},
          after: {
            'c1': ['1'],
            'c4': ['4'],
            'c5': ['5'],
            'c6': ['6'],
            'c7': ['7'],
          },
          fingerprintsByRaw: {
            '1': realZoe,
            '4': fingerprintsMatching(zach),
            '5': fingerprintsMatching(zoe),
            '6': fingerprintsMatching(zoe),
            '7': fingerprintsMatching(zach),
          },
        ),
        {'6': zoe, '7': zach},
      );
    });

    test('a fake merged into a contact from before: only its own raw '
        'contact', () {
      // A real Zoe Zen (raw 1, another account, with only a name) that
      // Android linked with the new fake (raw 6).
      expect(
        createdByPending(
          PendingCreate(maxRawId: 5, entries: [zoe]),
          recorded: const {},
          after: {
            'c1': ['1', '6'],
          },
          fingerprintsByRaw: {
            '1': fingerprintsOf('Zoe Zen', [], []).toSet(),
            '6': fingerprintsMatching(zoe),
          },
        ),
        {'6': zoe},
      );
    });

    test('two pending fakes Android merged with each other: each its own '
        'raw contact', () {
      expect(
        createdByPending(
          PendingCreate(maxRawId: 5, entries: [zoe, zach]),
          recorded: const {},
          after: {
            'c6': ['6', '7'],
          },
          fingerprintsByRaw: {
            '6': fingerprintsMatching(zach),
            '7': fingerprintsMatching(zoe),
          },
        ),
        {'6': zach, '7': zoe},
      );
    });

    test('with an empty address book before it, every raw contact not '
        'recorded is new', () {
      expect(
        createdByPending(
          PendingCreate(maxRawId: null, entries: [zoe]),
          recorded: {'1'},
          after: {
            'c1': ['1'],
            'c2': ['2'],
          },
          fingerprintsByRaw: {
            '1': fingerprintsMatching(zoe),
            '2': fingerprintsMatching(zoe),
          },
        ),
        {'2': zoe},
      );
    });

    test("a raw ID that isn't a number counts as old", () {
      expect(
        createdByPending(
          PendingCreate(maxRawId: 5, entries: [zoe]),
          recorded: const {},
          after: {
            'cx': ['x'],
          },
          fingerprintsByRaw: {'x': fingerprintsMatching(zoe)},
        ),
        isEmpty,
      );
    });

    test('a pending fake matched by two new contacts is left out', () {
      expect(
        createdByPending(
          PendingCreate(maxRawId: 5, entries: [zoe]),
          recorded: const {},
          after: {
            'c6': ['6'],
            'c7': ['7'],
          },
          fingerprintsByRaw: {
            '6': fingerprintsMatching(zoe),
            '7': fingerprintsMatching(zoe),
          },
        ),
        isEmpty,
      );
    });
  });

  group('planDelete', () {
    final zoe = fake('Zoe', 'Zen');
    final zach = fake('Zach', 'Zen');
    final aliceFps =
        fingerprintsOf('Alice Example', ['+15555550103'], []).toSet();

    test('deletes contacts made only of tracked, unchanged fakes', () {
      final ledger = Ledger({'20': zoe, '21': zach});
      final book = {
        'c20': ['20'],
        'c21': ['21'],
        'c1': ['1'], // real contact
      };
      final fps = {
        '20': fingerprintsMatching(zoe),
        '21': fingerprintsMatching(zach),
        '1': aliceFps,
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
          {'20': fingerprintsOf('Zoe Zen', [], []).toSet()});
      expect(plan.contactIdsToDelete, ['c20']);
    });

    test('never deletes a real contact with the same name as a fake', () {
      // Real "Zoe Zen" (raw 1) and fake "Zoe Zen" (raw 20) as separate contacts.
      final ledger = Ledger({'20': zoe});
      final book = {'c1': ['1'], 'c20': ['20']};
      final fps = {
        '1': fingerprintsOf('Zoe Zen', ['+15555550101'], []).toSet(),
        '20': fingerprintsMatching(zoe),
      };
      final plan = planDelete(ledger, book, fps);
      expect(plan.contactIdsToDelete, ['c20']);
    });

    test('leaves a fake alone if Android merged it with a real contact', () {
      final ledger = Ledger({'20': zoe});
      final book = {'c1': ['1', '20']};
      // Even if the real one has exactly the fake's details.
      final plan = planDelete(ledger, book, {
        '1': fingerprintsMatching(zoe),
        '20': fingerprintsMatching(zoe),
      });
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
            planDelete(ledger, {'c7': ['20']}, {'20': realFingerprints});
        expect(plan.contactIdsToDelete, isEmpty);
        expect(plan.rawContactsDeleted, 0);
        expect(plan.skippedChanged, 1);
        expect(plan.skippedMerged, 0);
        expect(plan.remaining.entries, {'20': zoe});
      }

      test('is not deleted if the name differs', () {
        expectLeftAlone(fingerprintsOf(
            'Alice Example', [zoe.phone], [zoe.email]).toSet());
      });

      test('is not deleted if the phone number differs', () {
        expectLeftAlone(
            fingerprintsOf('Zoe Zen', ['+15555550101'], [zoe.email]).toSet());
      });

      test('is not deleted if the email differs', () {
        expectLeftAlone(fingerprintsOf(
            'Zoe Zen', [zoe.phone], ['zoe@example.org']).toSet());
      });

      test('is not deleted if it has extra numbers or addresses', () {
        expectLeftAlone(fingerprintsOf('Zoe Zen',
            [zoe.phone, '+15555550101'], [zoe.email]).toSet());
        expectLeftAlone(fingerprintsOf('Zoe Zen', [zoe.phone],
            [zoe.email, 'zoe@example.org']).toSet());
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
          '20': aliceFps,
          '21': fingerprintsMatching(zach),
        });
        expect(plan.contactIdsToDelete, ['c21']);
        expect(plan.rawContactsDeleted, 1);
        expect(plan.skippedChanged, 1);
        expect(plan.remaining.entries, {'20': zoe});
      });
    });

    group('a contact into which Android merged two tracked fakes', () {
      // Android shows one name for it (Zoe Zen), and both numbers and
      // addresses; each raw contact is checked on its own.
      final ledger = Ledger({'20': zoe, '21': zach});
      final book = {'c20': ['20', '21']};

      test('is deleted if each is unchanged', () {
        final plan = planDelete(ledger, book, {
          '20': fingerprintsMatching(zoe),
          '21': fingerprintsMatching(zach),
        });
        expect(plan.contactIdsToDelete, ['c20']);
        expect(plan.rawContactsDeleted, 2);
        expect((plan.skippedMerged, plan.skippedChanged), (0, 0));
        expect(plan.remaining.isEmpty, isTrue);
      });

      test('is left alone, both fakes, if one of them changed: that one as '
          'changed, the other as merged', () {
        final plan = planDelete(ledger, book, {
          '20': fingerprintsMatching(zoe),
          '21': fingerprintsOf('Zach Zen', [zach.phone, '+15555550101'],
              [zach.email]).toSet(),
        });
        expect(plan.contactIdsToDelete, isEmpty);
        expect((plan.skippedMerged, plan.skippedChanged), (1, 1));
        expect(plan.remaining.entries, {'20': zoe, '21': zach});
      });

      test("is left alone if a raw contact has the other's details", () {
        // Each must match its own entry, not any of the contact's.
        final plan = planDelete(ledger, book, {
          '20': fingerprintsMatching(zach),
          '21': fingerprintsMatching(zoe),
        });
        expect(plan.contactIdsToDelete, isEmpty);
        expect((plan.skippedMerged, plan.skippedChanged), (0, 2));
      });

      test('is left alone if one raw contact has both fakes\' details', () {
        final plan = planDelete(ledger, book, {
          '20': {...fingerprintsMatching(zoe), ...fingerprintsMatching(zach)},
          '21': fingerprintsMatching(zach),
        });
        expect(plan.contactIdsToDelete, isEmpty);
        expect((plan.skippedMerged, plan.skippedChanged), (1, 1));
      });
    });

    test("an entry it can't read deletes nothing, even with exactly a "
        "fake's details", () {
      // Only a name, as early test builds stored them: raw 20 on its own,
      // and raw 22 linked with a recorded fake, raw 21.
      final ledger = Ledger.decode(jsonEncode({
        '20': 'Zoe Zen',
        '21': zach.toJson(),
        '22': {'name': 'Zach Zen', 'phone': null, 'email': null},
      }));
      final plan = planDelete(ledger, {
        'c20': ['20'],
        'c21': ['21', '22'],
      }, {
        '20': fingerprintsMatching(zoe),
        '21': fingerprintsMatching(zach),
        '22': fingerprintsOf('Zach Zen', [], []).toSet(),
      });
      expect(plan.contactIdsToDelete, isEmpty);
      // Raw 20 isn't this app's; raw 21 is, but shares its contact.
      expect((plan.skippedMerged, plan.skippedChanged), (1, 0));
      expect(plan.remaining.entries, {'21': zach});
    });
  });
}
