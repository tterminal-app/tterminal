# Contributing to tterminal

Thanks for wanting to help. A few things make the review go faster.

## Before you start

- **Bugs:** open an issue with your platform (OS version, device, x64 / arm64), what you did, what you expected and what happened. A screen recording helps a lot for input method problems.
- **Features:** open an issue first so we can agree on the approach before you spend time on it.

## Pull requests

- Keep each PR to one change. Small PRs get merged sooner.
- Run the checks that cover what you touched:
  ```sh
  cd core && cargo test && cargo clippy --all-targets -- -D warnings
  cd app && flutter analyze && flutter test
  ```
  `paint_cost_test` measures frame time and can fail on a busy machine; that one is fine to rerun.
- User-facing text goes through the localization files (`app/lib/l10n/app_en.arb` and `app_zh.arb`). If you don't read Chinese, add the English string and say so in the PR; we'll fill in the translation.
- Commit messages can be in English or Chinese. Say why, not just what.

## The CLA

The first time you open a PR, a bot asks you to sign the [Contributor License Agreement](CLA.md) by leaving a comment. You keep your copyright; the agreement lets the maintainer also distribute your change through the App Store, which GPL-only code would otherwise prevent. Every contribution stays available under the GPL.

## Code of conduct

Be kind and assume good intent. Harassment or personal attacks aren't welcome here, and maintainers will remove comments or block accounts that cross that line.

---

## 中文

謝謝你想幫忙。回報 bug 時請附上平台(作業系統版本、裝置、x64 / arm64)、操作步驟、預期和實際結果;輸入法相關的問題,附上錄影最有幫助。新功能請先開 issue 討論做法。

PR 請一次只做一件事,送出前跑一下上面列的檢查。介面文字請寫在 `app/lib/l10n/` 的 ARB 檔;不會中文的話,只加英文也沒關係,我們會補翻譯。

第一次開 PR 時,機器人會請你留言同意 [CLA](CLA.md)。著作權仍然是你的,這份協議只是讓維護者也能把你的修改放上 App Store;所有貢獻都會繼續以 GPL 公開。
