package io.github.thefanciestturtle.decoy_contacts

import android.content.ContentResolver
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Email
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.provider.ContactsContract.Contacts
import android.provider.ContactsContract.Data
import android.provider.ContactsContract.RawContacts
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

/**
 * Reads and deletes the address book's raw contacts one at a time, for the
 * app's Dart code (lib/flutter_contacts_gateway.dart).
 *
 * The flutter_contacts plugin reads and deletes whole contacts. When Android
 * merges two of the app's fakes into one contact, the app has to check each
 * fake on its own, so it reads each raw contact with its own name, phone
 * numbers and email addresses. And it deletes exactly the raw contacts it
 * checked: by the time it deletes them, Android may have merged someone
 * else's into the same contact.
 */
class RawContactsChannel(private val resolver: ContentResolver) :
    MethodChannel.MethodCallHandler {

    /**
     * Calls are handled one at a time on a background thread, not Android's
     * main thread: with thousands of contacts the queries, and encoding the
     * answer, take a while.
     */
    fun register(messenger: BinaryMessenger) {
        MethodChannel(
            messenger,
            CHANNEL,
            StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        ).setMethodCallHandler(this)
    }

    /**
     * `read`, with an optional list of contact IDs ("contactIds"): the raw
     * contacts of those contacts, or of every contact. Answers a list of maps
     * with "id", "contactId", "displayName", "phones" and "emails", in the
     * order of the raw contact IDs.
     *
     * `delete`, with a list of raw contact IDs ("ids"): deletes those raw
     * contacts and nothing else (see [delete]). Answers nothing. Without the
     * list it fails, and deletes nothing.
     */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_READ -> answer(result, "read_failed") {
                read(call.argument<List<String>>("contactIds"))
            }
            METHOD_DELETE -> answer(result, "delete_failed") {
                delete(
                    call.argument<List<String>>("ids")
                        ?: throw IllegalArgumentException("no raw contact IDs to delete"),
                )
                null
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Answers [result] with what [work] returns, or with an error coded
     * [errorCode] if it (or encoding the answer) throws. Even after an Error
     * (say, out of memory), so the Dart side never waits for nothing.
     */
    private inline fun answer(result: MethodChannel.Result, errorCode: String, work: () -> Any?) {
        try {
            result.success(work())
        } catch (e: Throwable) {
            result.error(errorCode, e.toString(), null)
        }
    }

    private class Raw(val id: Long, val contactId: Long, val displayName: String) {
        val phones = mutableListOf<String>()
        val emails = mutableListOf<String>()

        fun toMap(): Map<String, Any> = mapOf(
            "id" to id.toString(),
            "contactId" to contactId.toString(),
            "displayName" to displayName,
            "phones" to phones,
            "emails" to emails,
        )
    }

    /**
     * Three queries: the contacts, their raw contacts, and the raw contacts'
     * phone numbers and email addresses.
     *
     * The contacts are those of the default directory, as the plugin reads
     * them: those the Contacts app shows, without hidden ones such as Gmail's
     * auto-collected "Other contacts".
     *
     * If the first query gets no cursor (the contacts provider can't be
     * reached), that reads as no contacts, as the plugin's reads do. If a
     * later one (or a later batch of the first) gets none, the read fails:
     * half a read must not look whole.
     */
    private fun read(contactIds: List<String>?): List<Map<String, Any>> {
        val shown = HashSet<Long>()
        var firstBatch = true
        forEachBatch(contactIds) { batch ->
            val cursor = resolver.query(
                Contacts.CONTENT_URI.buildUpon()
                    .appendQueryParameter(
                        ContactsContract.DIRECTORY_PARAM_KEY,
                        ContactsContract.Directory.DEFAULT.toString(),
                    ).build(),
                arrayOf(Contacts._ID),
                batch?.let { inList(Contacts._ID, it) },
                batch?.toTypedArray(),
                null,
            )
            if (cursor == null) {
                if (firstBatch) return emptyList()
                throw IllegalStateException("no cursor for the contacts")
            }
            firstBatch = false
            cursor.use { while (it.moveToNext()) shown.add(it.getLong(0)) }
        }
        if (shown.isEmpty()) return emptyList()

        val raws = HashMap<Long, Raw>()
        forEachBatch(contactIds) { batch ->
            resolver.query(
                RawContacts.CONTENT_URI,
                arrayOf(RawContacts._ID, RawContacts.CONTACT_ID, RawContacts.DISPLAY_NAME_PRIMARY),
                // Raw contacts that wait for a sync to remove them have no
                // contact any more; those Android keeps out of every contact
                // (aggregation disabled) have none either.
                "${RawContacts.DELETED} = 0 AND ${RawContacts.CONTACT_ID} IS NOT NULL" +
                    (batch?.let { " AND " + inList(RawContacts.CONTACT_ID, it) } ?: ""),
                batch?.toTypedArray(),
                null,
            )?.use {
                while (it.moveToNext()) {
                    val contactId = it.getLong(1)
                    if (contactId in shown) {
                        val id = it.getLong(0)
                        raws[id] = Raw(id, contactId, it.getString(2) ?: "")
                    }
                }
            } ?: throw IllegalStateException("no cursor for the raw contacts")
        }
        if (raws.isEmpty()) return emptyList()

        // By the raw contacts found, not by contact: Android may move a raw
        // contact to another contact between the two queries. (Nor every row:
        // those of hidden contacts would only be read to be dropped.)
        forEachBatch(raws.keys.map { it.toString() }) { batch ->
            resolver.query(
                Data.CONTENT_URI,
                // DATA1 is Phone.NUMBER for a phone number and Email.ADDRESS
                // for an email address.
                arrayOf(Data.RAW_CONTACT_ID, Data.MIMETYPE, Data.DATA1),
                "${Data.MIMETYPE} IN (?, ?) AND " + inList(Data.RAW_CONTACT_ID, batch!!),
                arrayOf(Phone.CONTENT_ITEM_TYPE, Email.CONTENT_ITEM_TYPE) + batch,
                null,
            )?.use {
                while (it.moveToNext()) {
                    val raw = raws.getValue(it.getLong(0))
                    val value = it.getString(2) ?: ""
                    if (it.getString(1) == Phone.CONTENT_ITEM_TYPE) {
                        raw.phones.add(value)
                    } else {
                        raw.emails.add(value)
                    }
                }
            } ?: throw IllegalStateException("no cursor for the phone numbers and emails")
        }
        return raws.values.sortedBy { it.id }.map { it.toMap() }
    }

    /**
     * Deletes the raw contacts with the IDs [ids], and no others: not the
     * other raw contacts of their contacts. As the Contacts app does (no sync
     * adapter flag): one stored on the phone goes at once, with its details,
     * and so does its contact if it has no other raw contact; one in an
     * online account is marked as deleted, and its account's sync removes it
     * there too. IDs of raw contacts that are gone are passed over.
     */
    private fun delete(ids: List<String>) {
        // Always with the IDs as the selection: a delete without one would
        // delete every raw contact.
        for (batch in ids.chunked(MAX_IDS_PER_QUERY)) {
            resolver.delete(
                RawContacts.CONTENT_URI,
                inList(RawContacts._ID, batch),
                batch.toTypedArray(),
            )
        }
    }

    /** "column IN (?, ...)", with a placeholder for each of [ids]. */
    private fun inList(column: String, ids: List<String>) =
        "$column IN (${ids.joinToString(",") { "?" }})"

    /**
     * Runs [query] once with no batch (null) if [ids] is null, and otherwise
     * once per batch of [ids] (not at all for an empty list).
     */
    private inline fun forEachBatch(ids: List<String>?, query: (batch: List<String>?) -> Unit) {
        if (ids == null) {
            query(null)
            return
        }
        for (batch in ids.chunked(MAX_IDS_PER_QUERY)) query(batch)
    }

    companion object {
        const val CHANNEL = "io.github.thefanciestturtle.decoy_contacts/raw_contacts"
        const val METHOD_READ = "read"
        const val METHOD_DELETE = "delete"

        // SQLite allows 999 arguments per query; the Data query adds two.
        private const val MAX_IDS_PER_QUERY = 900
    }
}
