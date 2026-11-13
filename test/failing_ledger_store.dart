import 'package:decoy_contacts/fake_contacts_core.dart';
import 'package:decoy_contacts/settings_store.dart';

/// Fails [failures] saves, after letting the first [succeeding] through, as
/// on Android with the storage full: the ledger is kept in memory (later
/// loads return it), but not written.
class FailingLedgerStore extends LedgerStore {
  FailingLedgerStore(this.failures, {this.succeeding = 0});

  int failures;
  int succeeding;

  /// How many saves were tried, failed or not.
  int saves = 0;

  @override
  Future<void> save(Ledger ledger, {required PendingCreate? pending}) async {
    saves++;
    await super.save(ledger, pending: pending);
    if (succeeding > 0) {
      succeeding--;
      return;
    }
    if (failures > 0) {
      failures--;
      throw const LedgerNotSaved();
    }
  }
}
