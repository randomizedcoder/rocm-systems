# TOCTOU Race Conditions with chmod() in CUID Daemon and ROCm SMI

## Summary

Four locations across the codebase use `chmod()` after file creation, introducing a
time-of-check-time-of-use (TOCTOU) gap where an attacker could substitute the target
file (via symlink or hardlink) between creation and permission change. The most
security-sensitive instance is in the CUID daemon's HMAC key management, where a
cryptographic key file is created with default permissions before being locked down.

---

## Location 1: HMAC Key File Creation (CRITICAL PATH)

**File:** `projects/cuid/lib/src/hmac.cc`, line 163
**Function:** `cuid_hmac::set_hmac_key()`

### Full Context

```cpp
amdcuid_status_t cuid_hmac::set_hmac_key(const uint8_t key_data[key_length]) {
    if (geteuid() != 0) {
        return AMDCUID_STATUS_PERMISSION_DENIED;
    }

    if (key) {
        delete[] key;
    }
    key = new uint8_t[key_length];
    std::memcpy(key, key_data, key_length);

    // if key_file exists, delete it first
    if (std::remove(key_file_path.c_str()) != 0 && errno != ENOENT) {
        return AMDCUID_STATUS_KEY_ERROR;
    }

    // PROBLEM 1: std::ofstream does not support O_EXCL or O_NOFOLLOW
    std::ofstream key_file(key_file_path, std::ios::out | std::ios::binary);
    if (!key_file) {
        return AMDCUID_STATUS_KEY_ERROR;
    }
    key_file.write(reinterpret_cast<const char*>(key), key_length);
    if (!key_file) {
        key_file.close();
        return AMDCUID_STATUS_KEY_ERROR;
    }
    key_file.close();

    // PROBLEM 2: chmod on path, not file descriptor -- TOCTOU gap
    if (chmod(key_file_path.c_str(), S_IRUSR | S_IWUSR) != 0) {
        return AMDCUID_STATUS_PERMISSION_DENIED;
    }

    return AMDCUID_STATUS_SUCCESS;
}
```

### Analysis

- **What file:** `/opt/amdcuid/etc/hmac_key.bin` (hardcoded in `hmac.h` line 52)
- **Permissions set:** `S_IRUSR | S_IWUSR` (0600 -- owner read/write only)
- **How created:** `std::ofstream` -- no control over creation flags
- **O_EXCL used:** No. The code calls `std::remove()` first, then opens with ofstream.
  This creates a delete-then-create pattern with no atomic exclusivity.
- **O_NOFOLLOW used:** No. `std::ofstream` does not support this flag.
- **Runs as root:** Yes. The function explicitly checks `geteuid() != 0` and returns
  early if not root.

**Race window:** Between line 151 (`std::ofstream key_file(...)`) and line 163
(`chmod(...)`). During this window the file exists with the process umask permissions
(typically 0644 or 0622), meaning the 32-byte HMAC key is world-readable.

**Additional TOCTOU on delete:** Between line 146 (`std::remove()`) and line 151
(`std::ofstream key_file(...)`), an attacker could place a symlink at the key path
pointing to an arbitrary file. Since this runs as root, the ofstream open would
follow the symlink and overwrite the target.

**Directory:** `/opt/amdcuid/etc/` -- This is a root-owned system directory, NOT
world-writable. An attacker would need prior local access at a privileged level to
manipulate files here. This significantly limits exploitability.

---

## Location 2: CUID Data File Save

**File:** `projects/cuid/lib/src/cuid_file.cc`, lines 606 and 609
**Function:** `CuidFile::save()`

### Full Context

```cpp
// In save(), after writing all entries to a temp file:
    file.close();

    // Atomically move temp file to actual file
    if (rename(temp_path.c_str(), file_path_.c_str()) != 0) {
        unlink(temp_path.c_str());
        return AMDCUID_STATUS_PERMISSION_DENIED;
    }

    // Set permissions -- TOCTOU: chmod on path after rename
    if (!is_privileged_) {
        // Unprivileged file: readable by all (644)
        chmod(file_path_.c_str(), S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
    } else {
        // Privileged file: readable by root only (600)
        chmod(file_path_.c_str(), S_IRUSR | S_IWUSR);
    }
```

### Analysis

- **What files:** `/tmp/cuid` (unprivileged) and `/tmp/priv_cuid` (privileged).
  Paths defined in `cuid_util.h` lines 89 and 93.
- **Permissions set:** 0644 for unprivileged, 0600 for privileged
- **How created:** `std::ofstream` to a `.tmp` path, then `rename()` to final path
- **O_EXCL used:** No
- **O_NOFOLLOW used:** No

**Race window:** Between `rename()` (line 598) and `chmod()` (lines 606/609). After
rename completes, the file exists at the final path with whatever permissions the temp
file had (default umask). For the privileged file containing primary CUIDs, this means
sensitive data is briefly world-readable.

**Directory:** `/tmp/` -- This IS world-writable. An attacker with local access could:
1. Pre-create a symlink at `/tmp/priv_cuid` pointing to a target file
2. The `rename()` would replace the symlink with the real file (not follow it), so
   the symlink attack on rename itself is mitigated
3. However, between rename and chmod, a race could replace the file with a symlink,
   causing chmod to change permissions on an arbitrary file

**Mitigating factor:** The temp file path (`/tmp/cuid.tmp`, `/tmp/priv_cuid.tmp`) is
predictable, and the temp file itself is created without O_EXCL, so the temp file
creation is also vulnerable to symlink attacks.

---

## Location 3: ROCm SMI Logger

**File:** `projects/amdsmi/rocm_smi/src/rocm_smi_logger.cc`, line 502
**Function:** `ROCmLogging::Logger::initialize_resources()`

### Full Context

```cpp
m_File.open(logFileName, std::ios::out | std::ios::app);
// ... log type setup ...
chmod(logFileName, S_IRUSR | S_IRGRP | S_IROTH | S_IWUSR | S_IWGRP | S_IWOTH);
```

### Analysis

- **What file:** `/var/log/amd_smi_lib/AMD-SMI-lib.log` (defined at line 61-64)
- **Permissions set:** `0666` -- read/write for everyone
- **How created:** `std::ofstream::open()` with `std::ios::app`
- **O_EXCL used:** No
- **O_NOFOLLOW used:** No

**This is not really a TOCTOU issue -- it is a misconfigured permission issue.** The
file is being set to world-writable (0666). This means any local user can:
- Truncate or corrupt the log file
- Inject misleading log entries
- Use the log file as a signaling mechanism

**Directory:** `/var/log/amd_smi_lib/` -- Root-owned, not world-writable. The chmod
race window is less relevant since the permissions being set are already maximally
permissive. The real bug here is that 0666 on a log file is too broad.

---

## Location 4: ROCm SMI Temp File Storage

**File:** `projects/amdsmi/rocm_smi/src/rocm_smi_utils.cc`, line 690
**Function:** `storeTmpFile()`

### Full Context

```cpp
std::string fullTempFilePath = "/tmp/" + fullFileName + ".XXXXXX";
char* fileName = &fullTempFilePath[0];
int fd = mkstemp(fileName);
if (fd == -1) {
    return RSMI_STATUS_FILE_ERROR;
}

chmod(fileName, S_IRUSR | S_IRGRP | S_IROTH);  // 0444
ssize_t rc_write = write(fd, storageData.c_str(), storageData.size());
close(fd);
```

### Analysis

- **What file:** `/tmp/rocmsmi_<state>_<param>_<devid>.XXXXXX` (randomized by mkstemp)
- **Permissions set:** `S_IRUSR | S_IRGRP | S_IROTH` (0444 -- read-only for all)
- **How created:** `mkstemp()` -- creates with 0600, exclusive, no symlink following
- **O_EXCL used:** Yes, implicitly via mkstemp()
- **O_NOFOLLOW used:** Yes, implicitly via mkstemp()

**Race window:** Between `mkstemp()` (which creates at 0600) and `chmod()` (which
sets 0444). The file descriptor is still open and valid.

**Key observation:** `mkstemp()` already creates the file securely with 0600 and the
fd is held open. The chmod here is actually *widening* permissions (adding group/other
read). The TOCTOU is: between mkstemp and chmod, an attacker could replace the file
with a symlink. However, since mkstemp randomizes 6 characters in the filename, the
attacker cannot predict the path.

**Also notable:** The `write()` happens AFTER `chmod()`, so data is written to the fd
obtained from mkstemp, not via the path. This means even if the path were swapped, the
write goes to the original file (fd-based write is safe). The chmod is the only
path-based operation vulnerable to TOCTOU.

**Directory:** `/tmp/` -- world-writable, but filename is unpredictable.

---

## Exploitability Assessment

### Location 1 (hmac.cc) -- HMAC Key File

| Factor | Assessment |
|--------|-----------|
| Requires local access | Yes -- must be on the same machine |
| Directory writable by attacker | No -- `/opt/amdcuid/etc/` is root-owned |
| Filename predictable | Yes -- hardcoded path |
| Time window | Small -- microseconds between ofstream close and chmod |
| Impact if exploited | High -- HMAC key compromise breaks CUID integrity |
| Realistic attack | **Very Low** -- attacker needs existing root-level access to `/opt/amdcuid/etc/`, at which point they can read the key directly |

### Location 2 (cuid_file.cc) -- CUID Data Files

| Factor | Assessment |
|--------|-----------|
| Requires local access | Yes |
| Directory writable by attacker | Yes -- `/tmp/` is world-writable |
| Filename predictable | Yes -- `/tmp/cuid` and `/tmp/priv_cuid` |
| Time window | Small -- microseconds between rename and chmod |
| Impact if exploited | Medium -- could chmod arbitrary file if symlink placed in window |
| Realistic attack | **Low-Medium** -- `/tmp/` + predictable names makes this theoretically exploitable by a local user, but the window is very tight |

### Location 3 (rocm_smi_logger.cc) -- Log File

| Factor | Assessment |
|--------|-----------|
| TOCTOU relevance | Minimal -- the real issue is 0666 permissions |
| Directory writable by attacker | No -- `/var/log/amd_smi_lib/` |
| Impact | Low -- log tampering |
| Realistic attack | **Not a TOCTOU issue** -- it is a permission misconfiguration |

### Location 4 (rocm_smi_utils.cc) -- Temp Storage

| Factor | Assessment |
|--------|-----------|
| Requires local access | Yes |
| Directory writable by attacker | Yes -- `/tmp/` |
| Filename predictable | No -- mkstemp randomizes 6 chars |
| Time window | Small |
| Impact if exploited | Low -- could chmod wrong file to 0444 (read-only) |
| Realistic attack | **Very Low** -- unpredictable filename + low-impact permission change |

---

## Proposed Fixes

### Fix 1: hmac.cc -- Use open() with O_CREAT|O_EXCL|O_NOFOLLOW and fchmod()

```cpp
amdcuid_status_t cuid_hmac::set_hmac_key(const uint8_t key_data[key_length]) {
    if (geteuid() != 0) {
        return AMDCUID_STATUS_PERMISSION_DENIED;
    }

    if (key) {
        delete[] key;
    }
    key = new uint8_t[key_length];
    std::memcpy(key, key_data, key_length);

    // Remove existing key file
    if (unlink(key_file_path.c_str()) != 0 && errno != ENOENT) {
        return AMDCUID_STATUS_KEY_ERROR;
    }

    // Create file with restrictive permissions from the start
    // O_CREAT|O_EXCL ensures atomic create (fails if file exists)
    // O_NOFOLLOW prevents symlink following
    // Mode 0600 set at creation time -- no TOCTOU window
    int fd = open(key_file_path.c_str(),
                  O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                  S_IRUSR | S_IWUSR);
    if (fd < 0) {
        return AMDCUID_STATUS_KEY_ERROR;
    }

    ssize_t written = write(fd, key, key_length);
    if (written != static_cast<ssize_t>(key_length)) {
        close(fd);
        unlink(key_file_path.c_str());
        return AMDCUID_STATUS_KEY_ERROR;
    }

    // fchmod on fd -- immune to TOCTOU
    if (fchmod(fd, S_IRUSR | S_IWUSR) != 0) {
        close(fd);
        return AMDCUID_STATUS_PERMISSION_DENIED;
    }

    close(fd);
    return AMDCUID_STATUS_SUCCESS;
}
```

**Key changes:**
- `open()` with `O_CREAT | O_EXCL` guarantees atomic creation (no symlink race)
- Mode `0600` passed directly to `open()` so the file is never world-readable
- `fchmod()` on the fd rather than `chmod()` on the path eliminates the TOCTOU
- `O_NOFOLLOW` prevents symlink traversal

### Fix 2: cuid_file.cc -- Set umask before temp file creation, use fchmod()

```cpp
amdcuid_status_t CuidFile::save() {
    CuidFileLock lock(file_path_, CuidLockType::EXCLUSIVE);
    if (!lock.acquire()) {
        LOG(ERROR, "CuidFile::save: Failed to acquire exclusive lock for " << file_path_);
        return AMDCUID_STATUS_FILE_ERROR;
    }

    // Set restrictive umask so temp file is created with safe permissions
    mode_t old_umask = umask(0077);

    std::string temp_path = file_path_ + ".tmp";

    // Use open() with O_EXCL to prevent symlink attacks in /tmp
    // First unlink any stale temp file
    unlink(temp_path.c_str());
    int fd = open(temp_path.c_str(),
                  O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                  is_privileged_ ? (S_IRUSR | S_IWUSR) : (S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH));
    if (fd < 0) {
        umask(old_umask);
        return AMDCUID_STATUS_PERMISSION_DENIED;
    }

    // Write content via fd (use fdopen or dprintf)
    FILE* file = fdopen(fd, "w");
    // ... write entries using fprintf(file, ...) ...

    fclose(file);  // also closes fd
    umask(old_umask);

    // rename is atomic on same filesystem
    if (rename(temp_path.c_str(), file_path_.c_str()) != 0) {
        unlink(temp_path.c_str());
        return AMDCUID_STATUS_PERMISSION_DENIED;
    }

    // No chmod needed -- permissions were set correctly at creation time
    // and rename preserves the source file's permissions
    return AMDCUID_STATUS_SUCCESS;
}
```

**Key changes:**
- File created with final permissions from the start via `open()` mode argument
- `O_EXCL | O_NOFOLLOW` prevents symlink attacks on the temp file in `/tmp`
- `rename()` preserves permissions, so no post-rename `chmod()` needed
- Ideally, move CUID files out of `/tmp` into `/run/amdcuid/` or `/var/lib/amdcuid/`

### Fix 3: rocm_smi_logger.cc -- Reduce permissions and use fchmod()

```cpp
void ROCmLogging::Logger::initialize_resources() {
    // ...
    int fd = open(logFileName, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW,
                  S_IRUSR | S_IWUSR | S_IRGRP);  // 0640 not 0666
    if (fd < 0) {
        std::cout << "WARNING: Issue opening log file" << std::endl;
        return;
    }
    // fchmod to ensure correct permissions even if file pre-existed
    fchmod(fd, S_IRUSR | S_IWUSR | S_IRGRP);  // 0640
    m_File.open(logFileName, std::ios::out | std::ios::app);
    close(fd);
    // ...
}
```

**Key changes:**
- Permissions reduced from 0666 to 0640 (owner rw, group read)
- Use `fchmod()` on fd instead of `chmod()` on path

### Fix 4: rocm_smi_utils.cc -- Use fchmod() on existing fd

```cpp
int fd = mkstemp(fileName);
if (fd == -1) {
    return RSMI_STATUS_FILE_ERROR;
}

// Use fchmod on the fd from mkstemp -- eliminates TOCTOU
fchmod(fd, S_IRUSR | S_IRGRP | S_IROTH);
ssize_t rc_write = write(fd, storageData.c_str(), storageData.size());
close(fd);
```

**Key change:** Replace `chmod(fileName, ...)` with `fchmod(fd, ...)`. The fd from
mkstemp is already validated and cannot be swapped by an attacker. This is a
one-line fix.

---

## Overall Severity Rating

### Location 1 (hmac.cc): Medium

The code handles cryptographic key material and runs as root, which makes the
theoretical impact high. However, the key file lives in `/opt/amdcuid/etc/` which
is root-owned and not world-writable. An attacker who can write to this directory
already has root access, making the TOCTOU moot in practice. The real concern is
defense-in-depth: if any other vulnerability grants partial write access to that
directory, this TOCTOU becomes a privilege escalation primitive.

**The `std::ofstream` usage is the bigger concern** -- it provides no way to prevent
symlink following or set creation-time permissions, and the key is briefly
world-readable under default umask.

### Location 2 (cuid_file.cc): Medium

Files in `/tmp/` with predictable names are a classic TOCTOU target. The privileged
CUID file containing primary CUIDs and hardware fingerprints is the sensitive one.
The rename-then-chmod pattern means there is a brief window. However, this requires
a local attacker who can win a tight race condition, and the data exposure is limited
to device identifiers (not credentials).

**Recommended improvement:** Move CUID files from `/tmp/` to `/run/amdcuid/` (a
tmpfs directory created by the daemon with restrictive permissions).

### Location 3 (rocm_smi_logger.cc): Low (not really TOCTOU)

This is a permission misconfiguration (0666 on a log file), not a meaningful TOCTOU.
The directory is root-owned. Fix the permissions to 0640.

### Location 4 (rocm_smi_utils.cc): Very Low

mkstemp already provides secure file creation. The filename is unpredictable. The
permission change (0600 to 0444) is a widening to read-only. The write uses the fd,
not the path. Still worth fixing with `fchmod()` for correctness, but exploitation
is essentially impossible.

### Composite Rating: **Medium (CWE-367)**

The pattern of chmod-after-creation is a recognized weakness (CWE-367: TOCTOU Race
Condition). The HMAC key handling and /tmp file usage are the primary concerns. In
practice, exploitation requires local access and precise timing. No remote attack
vector exists. The fixes are straightforward (use `open()` with `O_EXCL`, `fchmod()`
on fd) and should be applied as defense-in-depth.

---

## References

- CWE-367: Time-of-check Time-of-use (TOCTOU) Race Condition
- CWE-377: Insecure Temporary File
- CWE-379: Creation of Temporary File in Directory with Insecure Permissions
- `open(2)` man page: O_EXCL, O_NOFOLLOW flags
- `fchmod(2)` man page: file-descriptor-based permission setting
