# App Store listing (English)

Paste into App Store Connect. Character limits in parentheses.

## Name (30)

tterminal

## Subtitle (30)

SSH terminal that handles IMEs

## Promotional text (170)

Free to download, with everything unlocked for 14 days, then a one-time purchase. Type Chinese or Japanese over SSH without losing half of what you wrote.

## Description (4000)

Typing Chinese or Japanese over SSH on a phone usually goes wrong somewhere: half your composition disappears, a character gets sent twice, or wide characters knock the whole screen out of line. tterminal started as an attempt to fix exactly that.

Composition shows up at the cursor and only goes to the server once you've picked a candidate. Zhuyin, Cangjie, Pinyin and Japanese input all work.

The rest of what you'd expect from a terminal is here too. htop, vim and tmux behave, and scrolling is smooth. There's a row of esc, ctrl, tab and arrow keys above the keyboard, with one-tap ^C and ^D, and you can long-press and drag on the screen to use it as arrow keys. Log in with a password or a key, or generate a key right in the app. Host fingerprints are remembered on first connect; if one changes later, tterminal stops and shows you what changed before it connects.

Switch away to answer a message and your session is usually still there when you come back. While the app is in the background, the Dynamic Island shows how many connections are open. iOS only allows so much background time, though, so a long break will still drop them.

To share hosts between your iPhone and iPad, you can run your own sync server with a single docker command. Everything is encrypted on the device before it's sent, so the server only stores ciphertext. It's best kept at home on a NAS or a small box, not open to the internet, and reached over a VPN when you're out. The server code is on GitHub.

On an iPad or an unfolded iPhone Duo you get two columns: connections on the left, terminal on the right.

It's free to download and everything works for 14 days. After that, a one-time purchase keeps new connections working and covers every 1.x update. No subscription, no ads. If you don't buy it, your hosts and sync stay where they are. The app collects no data, and there's no account to sign up for.

The phone version doesn't have SFTP file browsing or mosh yet. If there's something you'd like to see, open an issue on GitHub.

## Keywords (100, comma-separated, don't repeat words from name/subtitle)

terminal,tmux,vim,linux,shell,remote,server,devops,raspberry pi,console,command line,keys

## What's new

First release.

## Review notes

App Review notes are one field for the whole app, not per language, so there's only one copy: the English note in listing.zh.md. It covers the demo SSH host the reviewer needs, starting the free trial on first launch ("Start 14-day trial", the $0 "14-day Trial" IAP), and where to find "Unlock tterminal" and Restore purchases (Settings → Trial & unlock). The per-IAP review notes are in iap.md.
