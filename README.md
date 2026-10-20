# Lexicon Loop for KOReader

Long-press a word, tap **Add to Lexicon Loop app**, and it is saved to your Lexicon Loop account (same `words` + `word_progress` rows the app creates).

## Install
1. Copy the `lexiconloop.koplugin` folder to `koreader/plugins/` on the Kobo (`.adds/koreader/plugins/`).
2. In KOReader open Tools > Plugin management and **disable "Vocabulary builder"**, so its button does not appear next to ours. Restart KOReader.

## Set up (once)
Tools > Lexicon Loop > **Log in** (email + password of your Lexicon Loop account). After login you pick the **workspace** and then the **folder**. Both stay the same until you change them in the same menu. The login is kept (refresh token) until you choose **Log out**. The password is never stored.

Source/target language default to German/Turkish and can be changed in the same menu.

## What gets saved
- `word`: the looked-up word
- `example_sentence`: the sentence around it in the book (when available)
- `notes`: `Book: <title>`
- `meaning` / CEFR level are left empty; use Generate in the app.
- A word already in the workspace is not added twice.

Needs Wi-Fi; KOReader asks to connect if it is off.
