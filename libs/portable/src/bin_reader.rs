use std::{
    fs::{self},
    io::{self, Cursor, Read, Write},
    path::Path,
};

#[cfg(all(windows, not(test)))]
const BIN_DATA: &[u8] = include_bytes!("../data.bin");
#[cfg(any(not(windows), test))]
const BIN_DATA: &[u8] = &[];
// 4bytes
const LENGTH: usize = 4;
const IDENTIFIER: &str = "labdesk";
const IDENTIFIER_LENGTH: usize = IDENTIFIER.len();
const MD5_LENGTH: usize = 32;
const BUF_SIZE: usize = 4096;

pub(crate) struct BinaryData {
    pub md5_code: &'static [u8],
    // compressed gzip data
    pub raw: &'static [u8],
    pub path: String,
}

pub(crate) struct BinaryReader {
    pub files: Vec<BinaryData>,
    pub exe: String,
}

impl Default for BinaryReader {
    fn default() -> Self {
        Self::from_bytes(BIN_DATA).expect("invalid embedded portable payload")
    }
}

impl BinaryData {
    fn decompress(&self) -> Vec<u8> {
        let cursor = Cursor::new(self.raw);
        let mut decoder = brotli::Decompressor::new(cursor, BUF_SIZE);
        let mut buf = Vec::new();
        decoder.read_to_end(&mut buf).ok();
        buf
    }

    pub fn write_to_file(&self, prefix: &Path) {
        let p = prefix.join(&self.path);
        if let Some(parent) = p.parent() {
            if !parent.exists() {
                let _ = fs::create_dir_all(parent);
            }
        }
        if p.exists() {
            // check md5
            let f = fs::read(p.clone()).unwrap_or_default();
            let digest = format!("{:x}", md5::compute(&f));
            let md5_record = String::from_utf8_lossy(self.md5_code);
            if digest == md5_record {
                // same, skip this file
                println!("skip {}", &self.path);
                return;
            } else {
                println!("writing {}", p.display());
                println!("{} -> {}", md5_record, digest)
            }
        }
        let _ = fs::write(p, self.decompress());
    }
}

impl BinaryReader {
    pub(crate) fn from_bytes(data: &'static [u8]) -> io::Result<Self> {
        fn take(data: &'static [u8], base: &mut usize, length: usize) -> io::Result<&'static [u8]> {
            let end = base.checked_add(length).ok_or_else(invalid_payload)?;
            let value = data.get(*base..end).ok_or_else(invalid_payload)?;
            *base = end;
            Ok(value)
        }
        fn length(data: &'static [u8], base: &mut usize) -> io::Result<usize> {
            Ok(u32::from_be_bytes(take(data, base, LENGTH)?.try_into().unwrap()) as usize)
        }
        let mut base: usize = 0;
        let mut parsed = vec![];
        if take(data, &mut base, IDENTIFIER_LENGTH)? != IDENTIFIER.as_bytes() {
            return Err(invalid_payload());
        }
        loop {
            if data.get(base..base.saturating_add(IDENTIFIER_LENGTH)) == Some(IDENTIFIER.as_bytes())
            {
                base += IDENTIFIER_LENGTH;
                break;
            }
            let path_length = length(data, &mut base)?;
            let path = std::str::from_utf8(take(data, &mut base, path_length)?)
                .map_err(|_| invalid_payload())?
                .to_owned();
            let file_length = length(data, &mut base)?;
            let raw = take(data, &mut base, file_length)?;
            let md5 = take(data, &mut base, MD5_LENGTH)?;
            parsed.push(BinaryData {
                md5_code: md5,
                raw,
                path,
            });
        }
        let exe = std::str::from_utf8(data.get(base..).ok_or_else(invalid_payload)?)
            .map_err(|_| invalid_payload())?
            .to_owned();
        Ok(Self { files: parsed, exe })
    }

    /// Used only inside an atomically created, private update directory. The
    /// signed outer executable authenticates these bytes; MD5 detects pack errors.
    pub(crate) fn extract_update(&self, prefix: &Path) -> io::Result<std::path::PathBuf> {
        validate_payload_path(&self.exe)?;
        if !self.files.iter().any(|file| file.path == self.exe) {
            return Err(invalid_payload());
        }
        for file in &self.files {
            validate_payload_path(&file.path)?;
        }
        for file in &self.files {
            let path = prefix.join(&file.path);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut content = Vec::new();
            brotli::Decompressor::new(Cursor::new(file.raw), BUF_SIZE).read_to_end(&mut content)?;
            if format!("{:x}", md5::compute(&content)).as_bytes() != file.md5_code {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Portable payload checksum mismatch",
                ));
            }
            let mut output = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(path)?;
            output.write_all(&content)?;
            output.sync_all()?;
        }
        Ok(prefix.join(&self.exe))
    }

    #[cfg(linux)]
    pub fn configure_permission(&self, prefix: &Path) {
        use std::os::unix::prelude::PermissionsExt;

        let exe_path = prefix.join(&self.exe);
        if exe_path.exists() {
            if let Ok(f) = File::open(exe_path) {
                if let Ok(meta) = f.metadata() {
                    let mut permissions = meta.permissions();
                    permissions.set_mode(0o755);
                    f.set_permissions(permissions).ok();
                }
            }
        }
    }
}

fn invalid_payload() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "Invalid embedded portable payload",
    )
}

fn validate_payload_path(path: &str) -> io::Result<()> {
    if path.is_empty()
        || path.contains(':')
        || path.chars().any(|value| value <= '\u{1f}')
        || path.starts_with(['/', '\\'])
    {
        return Err(invalid_payload());
    }
    // generate.py emits one relative root marker (./ or .\\) in each entry.
    let relative = path
        .strip_prefix("./")
        .or_else(|| path.strip_prefix(".\\"))
        .unwrap_or(path);
    for component in relative.split(['/', '\\']) {
        let stem = component
            .split('.')
            .next()
            .unwrap_or("")
            .to_ascii_uppercase();
        if component.is_empty()
            || component == "."
            || component == ".."
            || component.ends_with(['.', ' '])
            || component.contains(['<', '>', '"', '|', '?', '*'])
            || matches!(
                stem.as_str(),
                "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
            )
            || ((stem.starts_with("COM") || stem.starts_with("LPT"))
                && matches!(
                    &stem[3..],
                    "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
                ))
        {
            return Err(invalid_payload());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn update_archive_rejects_windows_escape_and_device_paths() {
        for path in [
            "../outside.exe",
            "./../outside.exe",
            "C:\\outside.exe",
            "\\\\server\\payload.exe",
            "./C:\\outside.exe",
            "data/file:stream",
            "CON.txt",
            "aux",
            "COM1.dll",
            "COM¹.dll",
            "LPT²",
            "NUL ",
            "folder./payload.exe",
            "bad\u{1f}file",
            "././payload.exe",
        ] {
            assert!(validate_payload_path(path).is_err(), "accepted {path:?}");
        }
        for path in [
            "./labdesk.exe",
            ".\\labdesk.exe",
            "./data/liblabdesk.dll",
            "data\\normal !&^().bin",
        ] {
            assert!(validate_payload_path(path).is_ok(), "rejected {path:?}");
        }
    }

    #[test]
    fn update_archive_rejects_truncated_or_invalid_package() {
        for bytes in [b"".as_slice(), b"labdes", b"labdesk", b"labdesk\0\0\0\x80"] {
            assert!(BinaryReader::from_bytes(bytes).is_err());
        }
    }

    #[test]
    #[ignore = "run scripts/test-windows-secure-update.py to generate a real archive fixture"]
    fn update_archive_roundtrips_the_real_generator_and_fails_closed() {
        let fixture =
            std::env::var_os("LABDESK_PORTABLE_FIXTURE").expect("missing generator fixture");
        let fixture = Path::new(&fixture);
        let data = Box::leak(
            fs::read(fixture.join("data.bin"))
                .unwrap()
                .into_boxed_slice(),
        );
        let reader = BinaryReader::from_bytes(data).unwrap();
        let output = fixture.join("extracted");
        fs::create_dir(&output).unwrap();
        let executable = reader.extract_update(&output).unwrap();
        assert_eq!(
            fs::read(executable).unwrap(),
            b"harmless executable fixture\r\n"
        );
        assert_eq!(
            fs::read(output.join("data/liblabdesk.dll")).unwrap(),
            b"harmless DLL fixture\0"
        );
        assert!(
            reader.extract_update(&output).is_err(),
            "must not overwrite existing destinations"
        );

        let mut broken = BinaryReader::from_bytes(data).unwrap();
        broken.files[0].md5_code = b"00000000000000000000000000000000";
        let rejected = fixture.join("rejected");
        fs::create_dir(&rejected).unwrap();
        assert!(broken.extract_update(&rejected).is_err());

        let mut traversal = BinaryReader::from_bytes(data).unwrap();
        traversal.files[0].path = "../escaped.exe".to_owned();
        assert!(traversal.extract_update(&rejected).is_err());
        assert!(!fixture.join("escaped.exe").exists());
    }
}
