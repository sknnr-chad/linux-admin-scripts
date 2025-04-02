# linux-admin-scripts
A collection of helpful linux admin scripts

# User Management Script

This Bash script is a comprehensive user management tool designed for system administrators working on Unix-like systems. It provides a menu-driven interface to add new users, delete existing ones, review user details, and manage SSH keys—supporting both Ed25519 and ECDSA key types.

## Features

- **Root Privilege Verification:**  
  Ensures the script runs with root privileges to perform system-level modifications.

- **Interactive Menu:**  
  A clear, text-based menu guides you through various operations, making it user-friendly for both beginners and advanced users.

- **Dry-Run Mode:**  
  Use the `--dry-run` flag to simulate actions without applying changes. This helps in testing and validating the commands before making actual modifications.

- **User Creation and Deletion:**  
  - **Creation:** Prompts for a validated username and a public key (accepting Ed25519 and ECDSA keys).  
  - **Deletion:** Removes users and their home directories.

- **SSH Key Management:**  
  - **Adding Keys:** Append new SSH keys to an existing user's `authorized_keys` file.  
  - **Revoking Keys:** Remove specific keys from the file.  
  - **Rotating Keys:** Replace an existing key with a new one.

- **Security and Permissions:**  
  The script sets correct permissions for SSH directories and files and updates the sudoers file securely.

- **Modular Design:**  
  Each function is well encapsulated, making the script easy to maintain and extend.

## Usage

1. **Run as Root:**  
   Execute the script as the root user or using `sudo` to ensure all commands function correctly.

2. **Dry-Run Option:**  
   Run with the `--dry-run` flag to simulate actions:
   ```bash
   sudo ./add_user.sh --dry-run
