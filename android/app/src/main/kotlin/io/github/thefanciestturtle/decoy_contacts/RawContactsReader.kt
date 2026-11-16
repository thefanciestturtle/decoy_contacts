package io.github.thefanciestturtle.decoy_contacts

import android.content.ContentResolver
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Email
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.provider.ContactsContract.Contacts
import android.provider.ContactsContract.Data
import android.provider.ContactsContract.RawContacts
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Reads the address book one raw contact at a time, for the app's Dart code
 * (lib/flutter_contacts_gateway.dart): each raw contact with the contact it
 * is part of, and its own display name, phone numbers and email addresses.
 *
 * The flutter_contacts plugin reads whole contacts, with one name each. When
 * Android merges two of the app's fakes into one contact, the app has to
 * check each fake on its own, so it needs each raw contact's own name.
 */
class RawContactsReader(private val resolver: ContentResolver) :
    MethodChannel.MethodCallHandler {

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    /**
     * `read`, with an optional list of contact IDs ("contactIds"): the raw
     * contacts of those contacts, or of every contact. Answers a list of maps
     * with "id", "contactId", "displayName", "phones" and "emails", in the
     * order of the raw contact IDs.
     */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != METHOD_READ) {
            result.notImplemented()
            return
        }
        val contactIds = call.argument<List<String>>("contactIds")
        // Off the main thread: with thousands of contacts the queries take a
        // while. The answer goes back on the main thread, also after an Error
        // (say, out of memory), so the Dart side never waits for nothing.
        executor.execute {
            try {
                val raws = read(contactIds)
                mainThread.post { result.success(raws) }
            } catch (e: Throwable) {
                mainThread.post { result.error("read_failed", e.toString(), null) }
            }
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
        forEachBatch(contactIds) { filter, args ->
            val cursor = resolver.query(
                Contacts.CONTENT_URI.buildUpon()
                    .appendQueryParameter(
                        ContactsContract.DIRECTORY_PARAM_KEY,
                        ContactsContract.Directory.DEFAULT.toString(),
                    ).build(),
                arrayOf(Contacts._ID),
                filter(Contacts._ID).removePrefix(" AND ").ifEmpty { null },
                args,
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
        forEachBatch(contactIds) { filter, args ->
            val cursor = resolver.query(
                RawContacts.CONTENT_URI,
                arrayOf(RawContacts._ID, RawContacts.CONTACT_ID, RawContacts.DISPLAY_NAME_PRIMARY),
                // Raw contacts that wait for a sync to remove them have no
                // contact any more; those Android keeps out of every contact
                // (aggregation disabled) have none either.
                "${RawContacts.DELETED} = 0 AND ${RawContacts.CONTACT_ID} IS NOT NULL" +
                    filter(RawContacts.CONTACT_ID),
                args,
                null,
            ) ?: throw IllegalStateException("no cursor for the raw contacts")
            cursor.use {
                while (it.moveToNext()) {
                    val contactId = it.getLong(1)
                    if (contactId in shown) {
                        val id = it.getLong(0)
                        raws[id] = Raw(id, contactId, it.getString(2) ?: "")
                    }
                }
            }
        }
        if (raws.isEmpty()) return emptyList()

        // By the raw contacts found, not by contact: Android may move a raw
        // contact to another contact between the two queries. (Nor every row:
        // those of hidden contacts would only be read to be dropped.)
        forEachBatch(raws.keys.map { it.toString() }) { filter, args ->
            val cursor = resolver.query(
                Data.CONTENT_URI,
                // DATA1 is Phone.NUMBER for a phone number and Email.ADDRESS
                // for an email address.
                arrayOf(Data.RAW_CONTACT_ID, Data.MIMETYPE, Data.DATA1),
                "${Data.MIMETYPE} IN (?, ?)" + filter(Data.RAW_CONTACT_ID),
                arrayOf(Phone.CONTENT_ITEM_TYPE, Email.CONTENT_ITEM_TYPE) + args,
                null,
            ) ?: throw IllegalStateException("no cursor for the phone numbers and emails")
            cursor.use {
                while (it.moveToNext()) {
                    val raw = raws.getValue(it.getLong(0))
                    val value = it.getString(2) ?: ""
                    if (it.getString(1) == Phone.CONTENT_ITEM_TYPE) {
                        raw.phones.add(value)
                    } else {
                        raw.emails.add(value)
                    }
                }
            }
        }
        return raws.values.sortedBy { it.id }.map { it.toMap() }
    }

    /**
     * Runs [query] once with no filter, or once per batch of [ids] (none for
     * an empty list). [query] gets a function that turns an ID column into
     * the selection to add (" AND column IN (...)", or "" with no filter),
     * and the arguments it needs.
     */
    private inline fun forEachBatch(
        ids: List<String>?,
        query: (filter: (String) -> String, args: Array<String>) -> Unit,
    ) {
        if (ids == null) {
            query({ "" }, emptyArray())
            return
        }
        for (batch in ids.chunked(MAX_IDS_PER_QUERY)) {
            query(
                { column -> " AND $column IN (${batch.joinToString(",") { "?" }})" },
                batch.toTypedArray(),
            )
        }
    }

    companion object {
        const val CHANNEL = "io.github.thefanciestturtle.decoy_contacts/raw_contacts"
        const val METHOD_READ = "read"

        // SQLite allows 999 arguments per query; the Data query adds two.
        private const val MAX_IDS_PER_QUERY = 900

        private val executor = Executors.newSingleThreadExecutor()
        private val mainThread = Handler(Looper.getMainLooper())
    }
}
