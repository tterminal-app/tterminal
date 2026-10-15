//! Apple Keychain 版 KeyStore(iOS / macOS)。
//!
//! 直接呼叫 Security.framework:vault key 只在 Rust 裡流動,不經過 Dart / Swift
//! (維持 tterm-vault 的分層:上層拿不到 vault key 本體)。
//!
//! 項目是 generic password,service / account 由 Dart 指定;內容是
//! `tterm_vault::keystore::join_keys` 的格式(平常一把 32B key,換 key 途中兩把)。
//!
//! iOS 的 accessibility 用 `kSecAttrAccessibleAfterFirstUnlock`:
//! - **AfterFirstUnlock**:開機後解鎖過一次,之後鎖屏中也讀得到。app 在背景
//!   (SSH 保活、同步)或被系統預先啟動時開 vault 不會失敗;WhenUnlocked
//!   在鎖屏時開 app 會讀不到。
//! - **不加 ThisDeviceOnly**:加密備份(iCloud 備份一律加密)還原到新手機時
//!   key 跟著走,和同在備份裡的 vault.tv 一起回來,資料打得開。ThisDeviceOnly
//!   的話換手機後 vault.tv 回來了、key 沒有,只用一台裝置的人資料全部打不開
//!   (同步設定也在 vault.tv 裡,連從 server 拉回來都沒辦法)。未加密的電腦備份
//!   不會帶出可用的 key(只能還原回同一台),比舊版 key 檔明文躺在每份備份裡好。
//! - **不同步到 iCloud 鑰匙圈**(不設 kSecAttrSynchronizable):多裝置共用 vault
//!   走配對字串,不綁 Apple 帳號。
//!
//! macOS:app 沒有 team 簽章與 keychain-access-groups,用不了 data protection
//! keychain(會回 errSecMissingEntitlement),所以存登入鑰匙圈;項目的 ACL
//! 預設只信任建立它的 app。ad-hoc 簽章的開發版每次重編簽章都會變,讀取時
//! macOS 會跳出「允許存取」詢問。

use std::ffi::{c_char, c_void};

use anyhow::{bail, Context, Result};
use core_foundation_sys::base::{
    kCFAllocatorDefault, CFGetTypeID, CFIndex, CFRelease, CFTypeRef, OSStatus,
};
use core_foundation_sys::data::{
    CFDataCreate, CFDataGetBytePtr, CFDataGetLength, CFDataGetTypeID, CFDataRef,
};
use core_foundation_sys::dictionary::{
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks, CFDictionaryCreate,
    CFDictionaryRef,
};
use core_foundation_sys::number::kCFBooleanTrue;
use core_foundation_sys::string::{
    kCFStringEncodingUTF8, CFStringCreateWithBytes, CFStringGetCString, CFStringGetLength,
    CFStringGetMaximumSizeForEncoding, CFStringRef,
};
use tterm_vault::keystore::{join_keys, split_keys};
use tterm_vault::{KeyStore, VaultKey};

#[link(name = "Security", kind = "framework")]
extern "C" {
    static kSecClass: CFStringRef;
    static kSecClassGenericPassword: CFStringRef;
    static kSecAttrService: CFStringRef;
    static kSecAttrAccount: CFStringRef;
    static kSecAttrLabel: CFStringRef;
    static kSecValueData: CFStringRef;
    static kSecReturnData: CFStringRef;
    static kSecMatchLimit: CFStringRef;
    static kSecMatchLimitOne: CFStringRef;
    #[cfg(target_os = "ios")]
    static kSecAttrAccessible: CFStringRef;
    #[cfg(target_os = "ios")]
    static kSecAttrAccessibleAfterFirstUnlock: CFStringRef;

    fn SecItemCopyMatching(query: CFDictionaryRef, result: *mut CFTypeRef) -> OSStatus;
    fn SecItemAdd(attributes: CFDictionaryRef, result: *mut CFTypeRef) -> OSStatus;
    fn SecItemUpdate(query: CFDictionaryRef, attributes_to_update: CFDictionaryRef) -> OSStatus;
    #[cfg(test)]
    fn SecItemDelete(query: CFDictionaryRef) -> OSStatus;
    fn SecCopyErrorMessageString(status: OSStatus, reserved: *mut c_void) -> CFStringRef;
}

const ERR_SEC_SUCCESS: OSStatus = 0;
const ERR_SEC_ITEM_NOT_FOUND: OSStatus = -25300;
const ERR_SEC_DUPLICATE_ITEM: OSStatus = -25299;
const ERR_SEC_INTERACTION_NOT_ALLOWED: OSStatus = -25308;
const ERR_SEC_MISSING_ENTITLEMENT: OSStatus = -34018;
const ERR_SEC_USER_CANCELED: OSStatus = -128;
const ERR_SEC_AUTH_FAILED: OSStatus = -25293;

/// Keychain 項目在 macOS「鑰匙圈存取」裡顯示的名稱。
const LABEL: &str = "tterminal vault key";

pub struct KeychainKeyStore {
    service: String,
    account: String,
}

impl KeychainKeyStore {
    pub fn new(service: &str, account: &str) -> Self {
        Self {
            service: service.to_string(),
            account: account.to_string(),
        }
    }

    /// 刪掉這個項目(測試收尾用;app 本身從不刪 key)。
    #[cfg(test)]
    pub fn delete(&self) -> Result<()> {
        let (service, account) = (cf_string(&self.service)?, cf_string(&self.account)?);
        let query = cf_dict(&self.item(&service, &account))?;
        match unsafe { SecItemDelete(query.0 as CFDictionaryRef) } {
            ERR_SEC_SUCCESS | ERR_SEC_ITEM_NOT_FOUND => Ok(()),
            s => Err(sec_error("failed to delete the Keychain item", s)),
        }
    }

    /// 定位這個項目的三個屬性(class / service / account)。
    fn item(&self, service: &Cf, account: &Cf) -> Vec<(CFStringRef, CFTypeRef)> {
        unsafe {
            vec![
                (kSecClass, kSecClassGenericPassword as CFTypeRef),
                (kSecAttrService, service.0),
                (kSecAttrAccount, account.0),
            ]
        }
    }
}

impl KeyStore for KeychainKeyStore {
    fn load(&self) -> Result<Vec<VaultKey>> {
        let (service, account) = (cf_string(&self.service)?, cf_string(&self.account)?);
        let mut query = self.item(&service, &account);
        unsafe {
            query.push((kSecReturnData, kCFBooleanTrue as CFTypeRef));
            query.push((kSecMatchLimit, kSecMatchLimitOne as CFTypeRef));
        }
        let query = cf_dict(&query)?;
        let mut out: CFTypeRef = std::ptr::null();
        let status = unsafe { SecItemCopyMatching(query.0 as CFDictionaryRef, &mut out) };
        let out = Cf(out);
        match status {
            ERR_SEC_SUCCESS => {}
            // 只有「確定沒有」才回空;其他錯誤(鎖定、拒絕存取)一律是 Err
            ERR_SEC_ITEM_NOT_FOUND => return Ok(Vec::new()),
            s => return Err(sec_error("failed to read from the Keychain", s)),
        }
        if out.0.is_null() || unsafe { CFGetTypeID(out.0) != CFDataGetTypeID() } {
            bail!("the Keychain returned something other than data");
        }
        let bytes = unsafe {
            let data = out.0 as CFDataRef;
            std::slice::from_raw_parts(CFDataGetBytePtr(data), CFDataGetLength(data) as usize)
        };
        split_keys(bytes).context("the vault key in the Keychain is malformed")
    }

    fn store(&self, keys: &[VaultKey]) -> Result<()> {
        let payload = join_keys(keys)?;
        let (service, account) = (cf_string(&self.service)?, cf_string(&self.account)?);
        let data = cf_data(&payload)?;
        let label = cf_string(LABEL)?;
        let item = self.item(&service, &account);

        let attrs: Vec<_> = [(unsafe { kSecValueData }, data.0)]
            .into_iter()
            .chain(accessibility())
            .collect();

        // 已存在就原地更新(SecItemUpdate 是單一操作,不會有「刪了還沒加回去」的空窗)
        let mut add = item.clone();
        add.extend_from_slice(&attrs);
        add.push((unsafe { kSecAttrLabel }, label.0));
        let add = cf_dict(&add)?;
        match unsafe { SecItemAdd(add.0 as CFDictionaryRef, std::ptr::null_mut()) } {
            ERR_SEC_SUCCESS => return Ok(()),
            ERR_SEC_DUPLICATE_ITEM => {}
            s => return Err(sec_error("failed to write to the Keychain", s)),
        }
        let query = cf_dict(&item)?;
        let update = cf_dict(&attrs)?;
        match unsafe { SecItemUpdate(query.0 as CFDictionaryRef, update.0 as CFDictionaryRef) } {
            ERR_SEC_SUCCESS => Ok(()),
            s => Err(sec_error("failed to update the Keychain item", s)),
        }
    }
}

/// iOS 的保護等級(選 AfterFirstUnlock 的理由見檔頭);macOS 登入鑰匙圈不吃這個屬性。
fn accessibility() -> Option<(CFStringRef, CFTypeRef)> {
    #[cfg(target_os = "ios")]
    return Some(unsafe {
        (
            kSecAttrAccessible,
            kSecAttrAccessibleAfterFirstUnlock as CFTypeRef,
        )
    });
    #[cfg(not(target_os = "ios"))]
    None
}

/// 自己建立(Create/Copy)的 CF 物件,drop 時 CFRelease。
struct Cf(CFTypeRef);

impl Drop for Cf {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CFRelease(self.0) };
        }
    }
}

fn non_null(ptr: CFTypeRef, what: &str) -> Result<Cf> {
    if ptr.is_null() {
        bail!("failed to create {what}");
    }
    Ok(Cf(ptr))
}

fn cf_string(s: &str) -> Result<Cf> {
    let ptr = unsafe {
        CFStringCreateWithBytes(
            kCFAllocatorDefault,
            s.as_ptr(),
            s.len() as CFIndex,
            kCFStringEncodingUTF8,
            0,
        )
    };
    non_null(ptr as CFTypeRef, "CFString")
}

fn cf_data(bytes: &[u8]) -> Result<Cf> {
    let ptr = unsafe { CFDataCreate(kCFAllocatorDefault, bytes.as_ptr(), bytes.len() as CFIndex) };
    non_null(ptr as CFTypeRef, "CFData")
}

/// 建 CFDictionary(key/value 由 dictionary 自己 retain,呼叫端照常釋放自己的)。
fn cf_dict(pairs: &[(CFStringRef, CFTypeRef)]) -> Result<Cf> {
    let keys: Vec<*const c_void> = pairs.iter().map(|(k, _)| *k as *const c_void).collect();
    let values: Vec<*const c_void> = pairs.iter().map(|(_, v)| *v).collect();
    let ptr = unsafe {
        CFDictionaryCreate(
            kCFAllocatorDefault,
            keys.as_ptr(),
            values.as_ptr(),
            pairs.len() as CFIndex,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        )
    };
    non_null(ptr as CFTypeRef, "CFDictionary")
}

fn sec_error(what: &str, status: OSStatus) -> anyhow::Error {
    let hint = match status {
        ERR_SEC_INTERACTION_NOT_ALLOWED => Some("the device is locked; unlock it and try again"),
        ERR_SEC_USER_CANCELED | ERR_SEC_AUTH_FAILED => Some("access to the Keychain was not allowed"),
        ERR_SEC_MISSING_ENTITLEMENT => Some("the app is missing the Keychain entitlement"),
        _ => None,
    };
    let detail: Vec<String> = hint
        .map(str::to_string)
        .into_iter()
        .chain(sec_message(status))
        .collect();
    if detail.is_empty() {
        anyhow::anyhow!("{what} (OSStatus {status})")
    } else {
        anyhow::anyhow!("{what} (OSStatus {status}: {})", detail.join("; "))
    }
}

fn sec_message(status: OSStatus) -> Option<String> {
    let s = Cf(unsafe { SecCopyErrorMessageString(status, std::ptr::null_mut()) } as CFTypeRef);
    if s.0.is_null() {
        return None;
    }
    unsafe {
        let len = CFStringGetLength(s.0 as CFStringRef);
        let cap = CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
        let mut buf = vec![0u8; cap as usize];
        if CFStringGetCString(
            s.0 as CFStringRef,
            buf.as_mut_ptr() as *mut c_char,
            cap,
            kCFStringEncodingUTF8,
        ) == 0
        {
            return None;
        }
        let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        buf.truncate(end);
        String::from_utf8(buf).ok()
    }
}

/// 碰真的 Keychain(macOS 登入鑰匙圈),預設不跑:
/// `cargo test -p tterm-ffi keychain -- --ignored`
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tterm_vault::VaultStore;

    /// 每次用不同 service,測完刪掉,不會碰到 app 自己的項目。
    fn scratch_store() -> KeychainKeyStore {
        let tag: u64 = rand_tag();
        KeychainKeyStore::new(&format!("dev.tterm.tterminal.test-{tag:x}"), "vault-key")
    }

    fn rand_tag() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64
    }

    #[test]
    #[ignore = "寫入真的登入鑰匙圈"]
    fn keychain_roundtrip() {
        let ks = scratch_store();
        let result = std::panic::catch_unwind(|| {
            assert!(ks.load().unwrap().is_empty(), "不存在要回空,不是錯誤");
            ks.store(&[[1; 32]]).unwrap();
            assert_eq!(ks.load().unwrap(), vec![[1; 32]]);
            ks.store(&[[2; 32], [1; 32]]).unwrap(); // 已存在 → 原地更新
            assert_eq!(ks.load().unwrap(), vec![[2; 32], [1; 32]]);
        });
        ks.delete().unwrap();
        assert!(ks.load().unwrap().is_empty());
        result.unwrap();
    }

    #[test]
    #[ignore = "寫入真的登入鑰匙圈"]
    fn keychain_migrates_legacy_vault() {
        let dir = tempfile::TempDir::new().unwrap();
        {
            let mut v = VaultStore::open(dir.path()).unwrap();
            v.upsert(None, "host", "web1", json!({})).unwrap();
        }
        let probe = scratch_store();
        let result = std::panic::catch_unwind(|| {
            let v = VaultStore::open_with_key_store(dir.path(), Box::new(scratch_clone(&probe)))
                .unwrap();
            assert_eq!(v.snapshot_json()["records"][0]["name"], "web1");
            assert!(!dir.path().join("vault.key").exists());
            assert_eq!(probe.load().unwrap().len(), 1);
            drop(v);
            let v = VaultStore::open_with_key_store(dir.path(), Box::new(scratch_clone(&probe)))
                .unwrap();
            assert_eq!(v.snapshot_json()["records"][0]["name"], "web1");
        });
        probe.delete().unwrap();
        result.unwrap();
    }

    fn scratch_clone(ks: &KeychainKeyStore) -> KeychainKeyStore {
        KeychainKeyStore::new(&ks.service, &ks.account)
    }
}
