import 'package:fake_contacts/fake_contacts_core.dart';
import 'package:fake_contacts/settings_store.dart';

/// Fails the next [failures] saves as on Android with the storage full:
/// the ledger is kept in memory (later loads return it), but not written.
class FailingLedgerStore extends LedgerStore {
  FailingLedgerStore(this.failures);

  int failures;

  @override
  Future<void> save(Ledger ledger) async {
    await super.save(ledger);
    if (failures > 0) {
      failures--;
      throw const LedgerNotSaved();
    }
  }
}
