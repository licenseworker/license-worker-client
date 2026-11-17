//! Where the client keeps the licence between runs.
use serde::{Deserialize, Serialize};
use std::io;
use std::path::PathBuf;
use std::sync::Mutex;

/// What the client keeps between runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredLicence {
    /// The licence key, as the user entered it (trimmed).
    pub key: String,
    /// This device's activation on the server.
    pub instance_id: String,
    /// The last signed licence the server returned.
    pub token: String,
    /// The latest time this device has seen, unix seconds: the clock cannot be set back below it.
    pub high_water: i64,
}

/// Keeps one [`StoredLicence`]. Store it where users cannot edit it casually:
/// `KeyringStorage` (the `keyring` feature) is the usual choice.
///
/// A store that cannot be read should answer `None` from `load`; the app then
/// shows as not activated, and an activation writes it again.
pub trait Storage {
    /// The stored licence, or `None` when there is none (or it cannot be read).
    fn load(&self) -> Option<StoredLicence>;
    /// `None` forgets the licence. Forgetting what is not there is not an error.
    fn save(&self, value: Option<&StoredLicence>) -> io::Result<()>;
}

impl<S: Storage + ?Sized> Storage for &S {
    fn load(&self) -> Option<StoredLicence> {
        (**self).load()
    }
    fn save(&self, value: Option<&StoredLicence>) -> io::Result<()> {
        (**self).save(value)
    }
}

impl<S: Storage + ?Sized> Storage for Box<S> {
    fn load(&self) -> Option<StoredLicence> {
        (**self).load()
    }
    fn save(&self, value: Option<&StoredLicence>) -> io::Result<()> {
        (**self).save(value)
    }
}

impl<S: Storage + ?Sized> Storage for std::sync::Arc<S> {
    fn load(&self) -> Option<StoredLicence> {
        (**self).load()
    }
    fn save(&self, value: Option<&StoredLicence>) -> io::Result<()> {
        (**self).save(value)
    }
}

/// A JSON file. Simple, and easy for a user to delete or copy: prefer the
/// keyring where one exists. The parent folder is created on first save.
#[derive(Debug, Clone)]
pub struct FileStorage {
    path: PathBuf,
}

impl FileStorage {
    /// Storage in the JSON file at `path`. Nothing is read or written until it is used.
    pub fn new(path: impl Into<PathBuf>) -> Self {
        FileStorage { path: path.into() }
    }

    /// The file it uses.
    pub fn path(&self) -> &std::path::Path {
        &self.path
    }
}

impl Storage for FileStorage {
    fn load(&self) -> Option<StoredLicence> {
        std::fs::read_to_string(&self.path).ok().and_then(|s| serde_json::from_str(&s).ok())
    }

    fn save(&self, value: Option<&StoredLicence>) -> io::Result<()> {
        match value {
            Some(v) => {
                if let Some(dir) = self.path.parent().filter(|d| !d.as_os_str().is_empty()) {
                    std::fs::create_dir_all(dir)?;
                }
                let json = serde_json::to_string(v).map_err(io::Error::other)?;
                // Write beside it, then rename: a crash never leaves half a licence.
                let tmp = self.path.with_extension("tmp");
                std::fs::write(&tmp, json)?;
                std::fs::rename(&tmp, &self.path)
            }
            None => match std::fs::remove_file(&self.path) {
                Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
                r => r,
            },
        }
    }
}

/// In memory only: for tests, or an app that activates on every start.
#[derive(Debug, Default)]
pub struct MemoryStorage {
    value: Mutex<Option<StoredLicence>>,
}

impl MemoryStorage {
    /// Storage that starts out holding `value`.
    pub fn new(value: Option<StoredLicence>) -> Self {
        MemoryStorage { value: Mutex::new(value) }
    }
}

impl Storage for MemoryStorage {
    fn load(&self) -> Option<StoredLicence> {
        self.value.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
    fn save(&self, value: Option<&StoredLicence>) -> io::Result<()> {
        *self.value.lock().unwrap_or_else(|e| e.into_inner()) = value.cloned();
        Ok(())
    }
}

/// The OS credential store: Windows Credential Manager, macOS Keychain, Linux
/// Secret Service (GNOME Keyring, KWallet). One entry, `service` / `account`.
#[cfg(feature = "keyring")]
#[derive(Debug, Clone)]
pub struct KeyringStorage {
    service: String,
    account: String,
}

#[cfg(feature = "keyring")]
impl KeyringStorage {
    /// `service`: your app's identifier, e.g. `"com.example.myapp"`.
    /// `account`: any fixed name, e.g. `"licence"`.
    pub fn new(service: impl Into<String>, account: impl Into<String>) -> Self {
        KeyringStorage { service: service.into(), account: account.into() }
    }

    fn entry(&self) -> io::Result<keyring::Entry> {
        keyring::Entry::new(&self.service, &self.account).map_err(io::Error::other)
    }
}

#[cfg(feature = "keyring")]
impl Storage for KeyringStorage {
    fn load(&self) -> Option<StoredLicence> {
        let secret = self.entry().ok()?.get_password().ok()?;
        serde_json::from_str(&secret).ok()
    }

    fn save(&self, value: Option<&StoredLicence>) -> io::Result<()> {
        let entry = self.entry()?;
        match value {
            Some(v) => entry.set_password(&serde_json::to_string(v).map_err(io::Error::other)?).map_err(io::Error::other),
            None => match entry.delete_credential() {
                Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
                Err(e) => Err(io::Error::other(e)),
            },
        }
    }
}

/// This computer's name, to show next to the activation in the admin page
/// (`"computer"` when it has none).
pub fn default_instance_name() -> String {
    let name = gethostname::gethostname().to_string_lossy().trim().to_string();
    if name.is_empty() {
        "computer".into()
    } else {
        name
    }
}
