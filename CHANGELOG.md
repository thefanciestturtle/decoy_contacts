# Changes

The versions of Decoy Contacts, newest first.

## 2.0.2
* Create and Delete no longer lose track of the fake contacts they made when the contacts read as empty. If Android's contacts storage can't be reached (say it is disabled), they now say "Couldn't read your contacts. Try again." Before, Delete could forget its fakes, so the app could never delete them, and Create could make a second set.
* The version code inside each APK (the number Android and app stores compare to tell which is newer) is now ten times the build number plus 1 (`armeabi-v7a`), 2 (`arm64-v8a`) or 3 (`x86_64`), as F-Droid asks, instead of Flutter's own numbering. 2.0.1's were 1006, 2006 and 4006; 2.0.2's are 4011, 4012 and 4013. It installs over 2.0.1 as usual.

## 2.0.1
The app is unchanged. The store description now says how the app was made.

## 2.0.0
The first release of Decoy Contacts, a separate app from Fake Contacts (see ["If you have Fake Contacts"](https://github.com/thefanciestturtle/decoy_contacts#if-you-have-fake-contacts) in the README).
* Renamed to Decoy Contacts, with a new icon and its own app ID (`io.github.thefanciestturtle.decoy_contacts`): it is a separate app from Fake Contacts, and installs next to it.
* Only Android is supported; the iOS project is gone.
* Updated to current Flutter, Dart 3 and flutter_contacts; progress spinner and result messages (from https://github.com/BillDietrich/fake_contacts/pull/11).
* "Delete" now removes only contacts this app created, never real contacts with the same name.
* "Create" no longer makes duplicates.
* The app is excluded from Android backup and phone-to-phone transfer, and "Delete" checks each contact's name, phone number and email before removing it, so a record restored onto another phone can't delete real contacts.
* Default phone template moved from Algeria's +213 to the reserved UK drama range +44 7700 900xxx.
* "Create" and "Delete" ask first, with the exact number of contacts, and do no more than you confirmed.
* Big batches are done in groups, with a progress bar and a Stop button (Back stops them too).  If the app is closed or killed partway, it still knows which contacts it made.
* A status line above the buttons says how many fake contacts the app can delete.
* Under the fields, a preview shows how many contacts the lists make, with one example.  The phone and email templates get warnings as you type, and so do lists that would make more than 10,000 contacts.  "Create" is disabled while a name list is empty.  The phone template field has a keyboard with letters, so "n" can be typed.
* Once Android no longer asks for the Contacts permission, a dialog offers to open the app's settings.
* Failures are explained in plain words.  If one stops partway, the contacts already made are recorded, and the message says how far it got.
* Results show under the buttons until your next tap, instead of in a message that covered them.  Text fields are outlined, "Create" is filled, "Delete" is outlined in red, and the app follows the phone's dark theme.
* The menu (⋮) has "Reset to defaults" and "About" (what the app does and stores, the privacy policy, the version, the source code and the licenses).
* TalkBack reads the results.  With a keyboard or D-pad, the focus is shown, goes back to the button you used, and can leave a text field with the arrow keys.
* The privacy policy now says "It has no internet access."  The release build is checked to ask for no permission but access to contacts, so none for the internet.
* Release APKs come one for each type of processor, are signed with the app's own key, and are built so that a build of the same source gives the same files.
* Settings load once and save shortly after you stop typing (and when the app is backgrounded); the page scrolls on small screens; name lists wrap.

## Fake Contacts
The versions of the original app, Fake Contacts, under its own app ID (`me.billdietrich.fake_contacts`), as its README gave them.
### 1.8.0
Added Spanish description to Fastlane per https://github.com/BillDietrich/fake_contacts/pull/5
### 1.7.0
Changed color of delete button, added space between buttons, added a lot more names, cleaned up the code a little.
### 1.6.0
Got published on F-Droid.
### 1.0.0
Got working.
