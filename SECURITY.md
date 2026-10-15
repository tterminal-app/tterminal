# Security

tterminal handles SSH credentials and private keys, so security reports get priority.

**Please don't open a public issue for a vulnerability.** Report it privately through GitHub instead: go to the repository's **Security** tab and choose **Report a vulnerability**. Include what's affected, how to reproduce it and what an attacker could do with it.

You should hear back within a week. Once a fix ships, we're happy to credit you in the release notes if you'd like.

Things that are especially worth a look:

- how hosts, passwords and keys are stored on the device (`core/tterm-vault`)
- the sync protocol and server (`server/`, [docs/vault-sync-design.md](docs/vault-sync-design.md))
- SSH host key verification (`core/tterm-ssh`)

Known limitation: the vault key is currently stored in a file next to the vault inside the app's data directory. Moving it into the OS keychain is in progress.

---

發現安全性問題請**不要**開公開 issue,改用 repo 的 **Security → Report a vulnerability** 私下回報,一週內會回覆。
