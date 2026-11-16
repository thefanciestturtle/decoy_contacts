package io.github.thefanciestturtle.decoy_contacts

import android.content.ContentResolver
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract.CommonDataKinds.Email
import android.provider.ContactsContract.CommonDataKinds.Phone
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
        // while. The answer goes back on the main thread.
        executor.execute {
            try {
                val raws = read(contactIds)
                mainThread.post { result.success(raws) }
            } catch (e: Exception) {
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

    // A query that can't reach the contacts provider gives no cursor; that
    // reads as no contacts, as the plugin's reads do.
    private fun read(contactIds: List<String>?): List<Map<String, Any>> {
        val raws = LinkedHashMap<Long, Raw>()
        forEachBatch(contactIds) { filter, args ->
            resolver.query(
                RawContacts.CONTENT_URI,
                arrayOf(RawContacts._ID, RawContacts.CONTACT_ID, RawContacts.DISPLAY_NAME_PRIMARY),
                // Raw contacts that wait for a sync to remove them have no
                // contact any more; those Android keeps out of every contact
                // (aggregation disabled) have none either.
                "${RawContacts.DELETED} = 0 AND ${RawContacts.CONTACT_ID} IS NOT NULL" +
                    filter(RawContacts.CONTACT_ID),
                args,
                RawContacts._ID,
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(0)
                    raws[id] = Raw(id, cursor.getLong(1), cursor.getString(2) ?: "")
                }
            }
        }
        if (raws.isEmpty()) return emptyList()
        forEachBatch(contactIds) { filter, args ->
            resolver.query(
                Data.CONTENT_URI,
                // DATA1 is Phone.NUMBER for a phone number and Email.ADDRESS
                // for an email address.
                arrayOf(Data.RAW_CONTACT_ID, Data.MIMETYPE, Data.DATA1),
                "${Data.MIMETYPE} IN (?, ?)" + filter(Data.CONTACT_ID),
                arrayOf(Phone.CONTENT_ITEM_TYPE, Email.CONTENT_ITEM_TYPE) + args,
                Data._ID,
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    // Data of a raw contact the first query didn't find (say,
                    // one added meanwhile) is left out.
                    val raw = raws[cursor.getLong(0)]
                    if (raw != null) {
                        val value = cursor.getString(2) ?: ""
                        if (cursor.getString(1) == Phone.CONTENT_ITEM_TYPE) {
                            raw.phones.add(value)
                        } else {
                            raw.emails.add(value)
                        }
                    }
                }
            }
        }
        return raws.values.map { it.toMap() }
    }

    /**
     * Runs [query] once for every contact, or once per batch of [contactIds]
     * (none for an empty list). [query] gets a function that turns a contact
     * ID column into the selection to add, and the arguments it needs.
     */
    private fun forEachBatch(
        contactIds: List<String>?,
        query: (filter: (String) -> String, args: Array<String>) -> Unit,
    ) {
        if (contactIds == null) {
            query({ "" }, emptyArray())
            return
        }
        for (batch in contactIds.chunked(MAX_IDS_PER_QUERY)) {
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
