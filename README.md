# User Management Script

A bash script for managing Linux users and their SSH keys on Debian and RHEL-based systems.

## Features

- Add and delete users with SSH key authentication
- Manage SSH keys (add, revoke, rotate)
- Review existing users and their keys
- Fetch public keys directly from GitHub
- Configurable sudo privilege levels
- Dry-run mode for testing
- Comprehensive logging

## Requirements

- Bash 4.0 or higher
- Root privileges (run with `sudo`)
- `curl` (optional, for GitHub key fetching)

## Supported Distributions

| Family | Distributions |
|--------|---------------|
| Debian | Debian, Ubuntu, Linux Mint, Pop!_OS |
| RHEL | RHEL, CentOS, Fedora, Rocky Linux, AlmaLinux, Oracle Linux |

## Installation

```bash
# Download the script
curl -O https://example.com/user_management_v2.sh

# Make executable
chmod +x user_management_v2.sh

# Run as root
sudo ./user_management_v2.sh
```

## Usage

### Interactive Menu

Run the script without arguments to access the interactive menu:

```bash
sudo ./user_management_v2.sh
```

Menu options:

1. **Add a new user** — Create user with SSH key and configurable sudo
2. **Delete a user** — Remove user, home directory, and sudoers file
3. **Review users** — List all users with their SSH keys and sudo config
4. **Add SSH key** — Add a new key to an existing user
5. **Revoke SSH key** — Remove a specific key from a user
6. **Rotate SSH key** — Replace an existing key with a new one
7. **Modify sudo** — Change sudo privileges for existing user
8. **Show help** — Display help information
9. **Exit** — Quit the script

### Dry Run Mode

Test changes without modifying the system:

```bash
sudo ./user_management_v2.sh --dry-run
```

## Configuration

Edit these variables at the top of the script:

| Variable | Default | Description |
|----------|---------|-------------|
| `HOME_BASE` | `/home` | Base directory for user home folders |
| `LOG_FILE` | `/var/log/user_management.log` | Log file location |
| `LOCK_FILE` | `/var/run/user_management.lock` | Lock file for concurrency protection |
| `BACKUP_DIR` | `/var/backups/user_management` | Backup storage location |
| `ALLOW_RSA_KEYS` | `false` | Enable legacy RSA key support |

## Sudo Privilege Levels

When adding or modifying users, you can select from four privilege levels:

| Level | Description | Sudoers Entry |
|-------|-------------|---------------|
| None | No sudo access | *(no entry)* |
| Standard | Requires password for sudo | `user ALL=(ALL) ALL` |
| NOPASSWD | No password required (use sparingly) | `user ALL=(ALL) NOPASSWD: ALL` |
| Limited | NOPASSWD for specific commands only | `user ALL=(ALL) NOPASSWD: /path/to/cmd` |

### Recommendations

- **Standard** — Best for interactive human users
- **NOPASSWD** — Only for automation/service accounts
- **Limited** — When an account needs specific elevated actions only

## Allowed SSH Key Types

By default, the script accepts modern key types only:

- `ssh-ed25519` (recommended)
- `ecdsa-sha2-nistp256`
- `ecdsa-sha2-nistp384`
- `ecdsa-sha2-nistp521`

To enable legacy RSA keys, set `ALLOW_RSA_KEYS=true` in the script.

## File Locations

| File | Purpose |
|------|---------|
| `/var/log/user_management.log` | Operation logs |
| `/var/backups/user_management/` | Backups of modified files |
| `/etc/sudoers.d/<username>` | Per-user sudo configuration |
| `~/.ssh/authorized_keys` | User's SSH public keys |

## Examples

### Adding a User with GitHub Key

```
=== Add New User ===

Enter the new username: jsmith
Choose how to provide the SSH key:
  1) Paste key manually
  2) Fetch from GitHub
Enter your choice (1 or 2): 2
Enter the GitHub username: jsmith
Enter a comment for the key: Work laptop

Select sudo privilege level for jsmith:
  1) None - no sudo access
  2) Standard - sudo with password required
  3) NOPASSWD - sudo without password
  4) Limited - NOPASSWD for specific commands only
Enter choice (1-4): 2

User jsmith created successfully!
```

### Rotating a Key

```
=== Rotate SSH Key ===

Select a user:
1. jsmith
2. admin
Enter number: 1

Selected user: jsmith

SSH Keys for jsmith:
1. [ssh-ed25519] AAAAC3NzaC1lZDI1... - Work laptop - Added on 2025-01-15

Select a key to rotate (1-1): 1
Choose how to provide the SSH key:
  1) Paste key manually
  2) Fetch from GitHub
...
Key rotated successfully.
```

---

# Version History

## Version 2.0

Released with security hardening and new features.

### Security Fixes

| Issue | Severity | Fix |
|-------|----------|-----|
| Command injection in shell commands | High | Replaced `bash -c "echo..."` with `printf '%s\n'` via safe write functions |
| NOPASSWD granted to all users | Medium | Added interactive privilege level selection with 4 options |
| No sudoers syntax validation | Medium | Added `visudo -c` validation before writing sudoers files |
| Sudoers file not removed on user deletion | Medium | Added cleanup in `delete_user()` function |
| Duplicate sudoers configuration | Low | Removed redundant sudoers write in `add_user()` |

### Bug Fixes

| Issue | Fix |
|-------|-----|
| Duplicate key check incomplete | Now uses `grep -qF` on key data, handles keys with/without comments |
| sed delimiter collision in rotate_key | Replaced with `awk` temp-file approach |
| Off-by-one error in user selection | Fixed boundary check calculation |
| Silent curl failures | Added HTTP status code checking for GitHub API |
| Race condition with log file | Improved file existence check |

### New Features

| Feature | Description |
|---------|-------------|
| Concurrent execution protection | Lock file prevents multiple instances from running |
| Automatic backups | `authorized_keys` backed up before any modification |
| Modify sudo menu option | Change privileges for existing users (menu option 7) |
| Improved distro detection | Uses `/etc/os-release` with `ID_LIKE` fallback |
| RSA key toggle | `ALLOW_RSA_KEYS=true` enables legacy RSA support |
| Comment sanitization | Strips newlines and dangerous characters from input |
| System user protection | Prevents deleting users with UID < 1000 |
| Enhanced UI | Truncated key display, cleaner menu formatting |

### Improvements

| Area | Change |
|------|--------|
| Error handling | Commands return status instead of exiting immediately |
| Input validation | GitHub username format validation added |
| Code organization | Extracted common operations into reusable functions |
| Logging | More consistent log message formatting |

## Version 1.0

Initial release with basic functionality.

### Features

- Add/delete users with SSH key authentication
- Review users and their SSH keys
- Add, revoke, and rotate SSH keys
- Fetch keys from GitHub
- Dry-run mode
- Support for Debian and RHEL-based distributions
- Logging to file

### Known Issues (Fixed in v2.0)

- Command injection vulnerability in shell commands
- All users granted NOPASSWD sudo access
- No sudoers syntax validation
- Sudoers files not cleaned up on user deletion
- Incomplete duplicate key detection
- Potential sed delimiter collision
- No concurrent execution protection
- No backups before file modification

---

## Security Considerations

1. **Protect the script** — Only root should be able to modify it
   ```bash
   chown root:root user_management_v2.sh
   chmod 700 user_management_v2.sh
   ```

2. **Review logs regularly** — Check `/var/log/user_management.log` for unauthorized changes

3. **Use Standard sudo** — Prefer password-required sudo for human users

4. **Rotate keys periodically** — Establish a key rotation policy

5. **Secure private keys** — Always use a strong passphrase on SSH private keys

## Troubleshooting

### "Another instance is already running"

The lock file exists from a previous run. If no other instance is running:

```bash
rm /var/run/user_management.lock
```

### "Invalid sudoers syntax"

The sudoers file failed validation. Check your command paths for the limited sudo option. Commands must be full paths (e.g., `/usr/bin/systemctl` not `systemctl`).

### "Failed to fetch keys from GitHub"

- Verify the GitHub username exists
- Check network connectivity
- Ensure `curl` is installed

### Keys not working after rotation

1. Verify the key was written correctly:
   ```bash
   cat /home/username/.ssh/authorized_keys
   ```
2. Check file permissions:
   ```bash
   ls -la /home/username/.ssh/
   ```
   Should be: `.ssh` (700), `authorized_keys` (600)

3. Check ownership:
   ```bash
   stat /home/username/.ssh/authorized_keys
   ```
   Should be owned by the user

## License

MIT License — See LICENSE file for details.

## Contributing

1. Test changes with `--dry-run` first
2. Ensure compatibility with both Debian and RHEL families
3. Follow existing code style
4. Update this README for new features
