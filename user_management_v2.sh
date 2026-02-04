#!/bin/bash
# User Management Script v2.0
# Requires Bash 4 or higher
#
# Improvements over v1:
# - Configurable sudo privilege levels
# - Sudoers syntax validation with visudo
# - Proper cleanup on user deletion
# - Backup before modifying authorized_keys
# - Concurrent execution protection via lock file
# - Improved distro detection using /etc/os-release
# - Better input sanitization
# - Fixed duplicate key detection
# - RSA key support (optional)
# - curl error handling for GitHub key fetch

set -uo pipefail

# Configurable variables
HOME_BASE="/home"
LOG_FILE="/var/log/user_management.log"
LOCK_FILE="/var/run/user_management.lock"
BACKUP_DIR="/var/backups/user_management"

# Allow RSA keys? Set to true if you need legacy RSA support
ALLOW_RSA_KEYS=false

# Ensure LOG_FILE exists and is writable
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/user_management.log"
    touch "$LOG_FILE" 2>/dev/null
fi

# Ensure BACKUP_DIR exists
mkdir -p "$BACKUP_DIR" 2>/dev/null || BACKUP_DIR="/tmp/user_management_backups"
mkdir -p "$BACKUP_DIR" 2>/dev/null

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Acquire lock to prevent concurrent execution
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "Another instance of this script is already running."
    exit 1
fi

# Determine distro using /etc/os-release (more reliable)
detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint|pop)
                DISTRO="debian"
                ;;
            rhel|centos|fedora|rocky|alma|ol)
                DISTRO="rhel"
                ;;
            *)
                # Fallback to ID_LIKE if available
                case "${ID_LIKE:-}" in
                    *debian*|*ubuntu*)
                        DISTRO="debian"
                        ;;
                    *rhel*|*fedora*)
                        DISTRO="rhel"
                        ;;
                    *)
                        DISTRO="unknown"
                        ;;
                esac
                ;;
        esac
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
    elif [ -f /etc/redhat-release ]; then
        DISTRO="rhel"
    else
        DISTRO="unknown"
    fi
}

detect_distro

# Check for dry run mode from command line
DRY_RUN=false
for arg in "$@"; do
    if [ "$arg" == "--dry-run" ]; then
        DRY_RUN=true
    fi
done

# Logging function
log_msg() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$LOG_FILE"
}

# Function to execute commands safely (without shell redirection)
run_command() {
    log_msg "Executing: $*"
    if $DRY_RUN; then
        echo "Dry run: $*"
    else
        "$@"
        local status=$?
        if [ $status -ne 0 ]; then
            log_msg "Error: Command failed with status $status: $*"
            echo "Error: Command failed: $*"
            return $status
        fi
    fi
}

# Function to safely write content to a file (avoids shell injection)
safe_write_file() {
    local content="$1"
    local filepath="$2"
    local mode="${3:-644}"
    
    log_msg "Writing to file: $filepath"
    if $DRY_RUN; then
        echo "Dry run: Would write to $filepath"
    else
        printf '%s\n' "$content" > "$filepath"
        chmod "$mode" "$filepath"
    fi
}

# Function to safely append content to a file
safe_append_file() {
    local content="$1"
    local filepath="$2"
    
    log_msg "Appending to file: $filepath"
    if $DRY_RUN; then
        echo "Dry run: Would append to $filepath"
    else
        printf '%s\n' "$content" >> "$filepath"
    fi
}

# Function to backup a file before modification
backup_file() {
    local filepath="$1"
    if [ -f "$filepath" ]; then
        local filename
        filename=$(basename "$filepath")
        local backup_path="$BACKUP_DIR/${filename}.$(date +%Y%m%d_%H%M%S).bak"
        cp "$filepath" "$backup_path"
        log_msg "Backed up $filepath to $backup_path"
        echo "Backup created: $backup_path"
    fi
}

# Function to validate and write sudoers file
write_sudoers_file() {
    local username="$1"
    local content="$2"
    local sudoers_file="/etc/sudoers.d/$username"
    local temp_file="/etc/sudoers.d/${username}.tmp"
    
    if $DRY_RUN; then
        echo "Dry run: Would write sudoers file for $username"
        echo "Content: $content"
        return 0
    fi
    
    # Write to temp file first
    printf '%s\n' "$content" > "$temp_file"
    chmod 440 "$temp_file"
    
    # Validate with visudo
    if visudo -c -f "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$sudoers_file"
        log_msg "Sudoers file created for $username"
        return 0
    else
        rm -f "$temp_file"
        log_msg "Error: Invalid sudoers syntax for $username"
        echo "Error: Invalid sudoers syntax. File not created."
        return 1
    fi
}

# Function to remove sudoers file
remove_sudoers_file() {
    local username="$1"
    local sudoers_file="/etc/sudoers.d/$username"
    
    if [ -f "$sudoers_file" ]; then
        if $DRY_RUN; then
            echo "Dry run: Would remove $sudoers_file"
        else
            rm -f "$sudoers_file"
            log_msg "Removed sudoers file for $username"
        fi
    fi
}

# Function to select and assign sudo privileges
select_sudo_privileges() {
    local username="$1"
    
    echo ""
    echo "Select sudo privilege level for $username:"
    echo "  1) None - no sudo access (regular user)"
    echo "  2) Standard - sudo with password required"
    echo "  3) NOPASSWD - sudo without password (security risk, use sparingly)"
    echo "  4) Limited - NOPASSWD for specific commands only"
    echo ""
    read -p "Enter choice (1-4) [default: 2]: " sudo_choice
    sudo_choice="${sudo_choice:-2}"
    
    case "$sudo_choice" in
        1)
            echo "User will have no sudo privileges."
            log_msg "No sudo privileges assigned to $username"
            ;;
        2)
            # Add user to appropriate group
            case "$DISTRO" in
                debian)
                    run_command usermod -aG sudo "$username"
                    ;;
                rhel)
                    run_command usermod -aG wheel "$username"
                    ;;
            esac
            write_sudoers_file "$username" "$username ALL=(ALL) ALL"
            echo "Standard sudo access granted (password required)."
            ;;
        3)
            echo ""
            echo "WARNING: NOPASSWD grants full root access without password verification."
            echo "If the SSH key is compromised, the attacker gains complete system access."
            read -p "Are you absolutely sure? (yes/no): " confirm
            if [ "$confirm" == "yes" ]; then
                case "$DISTRO" in
                    debian)
                        run_command usermod -aG sudo "$username"
                        ;;
                    rhel)
                        run_command usermod -aG wheel "$username"
                        ;;
                esac
                write_sudoers_file "$username" "$username ALL=(ALL) NOPASSWD: ALL"
                echo "NOPASSWD sudo access granted."
            else
                echo "Falling back to standard sudo (password required)."
                case "$DISTRO" in
                    debian)
                        run_command usermod -aG sudo "$username"
                        ;;
                    rhel)
                        run_command usermod -aG wheel "$username"
                        ;;
                esac
                write_sudoers_file "$username" "$username ALL=(ALL) ALL"
            fi
            ;;
        4)
            echo ""
            echo "Enter the full paths of commands the user can run without password."
            echo "Example: /usr/bin/systemctl restart nginx, /usr/bin/journalctl"
            read -p "Commands (comma-separated): " commands
            
            if [ -z "$commands" ]; then
                echo "No commands specified. Granting no sudo access."
                return
            fi
            
            # Clean up the command list
            commands=$(echo "$commands" | sed 's/[[:space:]]*,[[:space:]]*/,/g')
            
            case "$DISTRO" in
                debian)
                    run_command usermod -aG sudo "$username"
                    ;;
                rhel)
                    run_command usermod -aG wheel "$username"
                    ;;
            esac
            write_sudoers_file "$username" "$username ALL=(ALL) NOPASSWD: $commands"
            echo "Limited NOPASSWD access granted for: $commands"
            ;;
        *)
            echo "Invalid choice. Defaulting to no sudo access."
            log_msg "Invalid sudo choice for $username, no privileges assigned"
            ;;
    esac
}

# Regular expression for allowed public keys
if $ALLOW_RSA_KEYS; then
    PUBLIC_KEY_REGEX='^(ssh-ed25519|ecdsa-sha2-(nistp256|nistp384|nistp521)|ssh-rsa)[[:space:]]+[A-Za-z0-9+/=]+$'
else
    PUBLIC_KEY_REGEX='^(ssh-ed25519|ecdsa-sha2-(nistp256|nistp384|nistp521))[[:space:]]+[A-Za-z0-9+/=]+$'
fi

# Helper function to obtain a public key either manually or from GitHub
get_public_key() {
    local method
    while true; do
        echo "Choose how to provide the SSH key:" > /dev/tty
        echo "  1) Paste key manually" > /dev/tty
        echo "  2) Fetch from GitHub" > /dev/tty
        read -p "Enter your choice (1 or 2): " method < /dev/tty
        if [[ "$method" == "1" || "$method" == "2" ]]; then
            break
        fi
        echo "Invalid selection." > /dev/tty
    done

    if [ "$method" == "1" ]; then
        echo "" > /dev/tty
        echo "Allowed key types: ssh-ed25519, ecdsa-sha2-nistp256/384/521" > /dev/tty
        if $ALLOW_RSA_KEYS; then
            echo "                   ssh-rsa (legacy)" > /dev/tty
        fi
        echo "Enter the key type and key data only (no comment)." > /dev/tty
        echo "" > /dev/tty
        
        while true; do
            read -p "Public key: " pub_key < /dev/tty
            if [[ $pub_key =~ $PUBLIC_KEY_REGEX ]]; then
                echo "$pub_key"
                return 0
            else
                echo "Invalid key format. Please check the key type and try again." > /dev/tty
            fi
        done
    else
        if ! command -v curl > /dev/null; then
            echo "Error: curl is required for fetching keys from GitHub." >&2
            return 1
        fi
        
        read -p "Enter the GitHub username: " github_user < /dev/tty
        
        # Validate GitHub username format
        if ! [[ "$github_user" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
            echo "Invalid GitHub username format." >&2
            return 1
        fi
        
        # Fetch keys with proper error handling
        local http_code
        local response
        response=$(curl -s -w "\n%{http_code}" "https://github.com/$github_user.keys")
        http_code=$(echo "$response" | tail -n1)
        keys=$(echo "$response" | sed '$d')
        
        if [ "$http_code" != "200" ]; then
            echo "Failed to fetch keys from GitHub (HTTP $http_code)." >&2
            return 1
        fi
        
        if [ -z "$keys" ]; then
            echo "No keys found for GitHub user $github_user." >&2
            return 1
        fi
        
        IFS=$'\n' read -rd '' -a key_array <<<"$keys"
        
        if [ ${#key_array[@]} -gt 1 ]; then
            echo "Multiple keys found for GitHub user $github_user:" > /dev/tty
            local i=1
            for key in "${key_array[@]}"; do
                # Show truncated key for readability
                local key_type key_data
                key_type=$(echo "$key" | awk '{print $1}')
                key_data=$(echo "$key" | awk '{print $2}')
                echo "  $i) $key_type ${key_data:0:20}...${key_data: -10}" > /dev/tty
                ((i++))
            done
            
            while true; do
                read -p "Select a key by number: " key_choice < /dev/tty
                if [[ "$key_choice" =~ ^[0-9]+$ ]] && [ "$key_choice" -ge 1 ] && [ "$key_choice" -le ${#key_array[@]} ]; then
                    selected_key="${key_array[$((key_choice-1))]}"
                    break
                else
                    echo "Invalid selection." > /dev/tty
                fi
            done
        else
            selected_key="${key_array[0]}"
        fi
        
        # Remove any existing comment – keep only the key type and key
        cleaned_key=$(echo "$selected_key" | awk '{print $1, $2}')
        
        if [[ $cleaned_key =~ $PUBLIC_KEY_REGEX ]]; then
            echo "$cleaned_key"
            return 0
        else
            echo "Fetched key type is not allowed." >&2
            if ! $ALLOW_RSA_KEYS && [[ "$cleaned_key" =~ ^ssh-rsa ]]; then
                echo "RSA keys are disabled. Enable with ALLOW_RSA_KEYS=true" >&2
            fi
            return 1
        fi
    fi
}

# Helper function to select a user from a list
select_user() {
    local prompt="$1"
    shift
    local users=("$@")
    
    if [ ${#users[@]} -eq 0 ]; then
        echo "No users found."
        return 1
    fi
    
    local i=1
    declare -A user_map
    for user in "${users[@]}"; do
        echo "$i. $user" > /dev/tty
        user_map[$i]="$user"
        ((i++))
    done
    
    local max_num=$((i - 1))
    read -p "$prompt" user_num < /dev/tty
    
    if ! [[ "$user_num" =~ ^[0-9]+$ ]] || [ "$user_num" -lt 1 ] || [ "$user_num" -gt "$max_num" ]; then
        echo "Invalid selection." > /dev/tty
        read -p "Press Enter to continue..." < /dev/tty
        return 1
    fi
    
    echo "${user_map[$user_num]}"
    return 0
}

# Function to sanitize comment text
sanitize_comment() {
    local comment="$1"
    # Remove newlines, carriage returns, and trim whitespace
    comment=$(echo "$comment" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "$comment"
}

# Function to add a new user
add_user() {
    echo "=== Add New User ==="
    echo ""
    
    while true; do
        read -p "Enter the new username (1-32 chars, alphanumeric/underscore/hyphen): " username
        if [[ $username =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,31}$ ]]; then
            break
        else
            echo "Invalid username. Must start with a letter and contain only alphanumeric, underscore, or hyphen."
        fi
    done

    if id -u "$username" > /dev/null 2>&1; then
        echo "User $username already exists."
        read -p "Press Enter to continue..."
        return
    fi

    # Obtain the public key
    public_key=$(get_public_key)
    if [ $? -ne 0 ] || [ -z "$public_key" ]; then
        echo "Failed to obtain a valid public key."
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi

    read -p "Enter a comment for the key (e.g., 'John's laptop'): " key_comment
    key_comment=$(sanitize_comment "$key_comment")
    key_comment="$key_comment - Added on $(date +%Y-%m-%d)"

    # Create user
    run_command useradd -m -s /bin/bash "$username" || { 
        echo "Failed to create user."
        read -p "Press Enter to continue..."
        return
    }
    run_command passwd -l "$username"
    
    # Setup SSH directory and authorized_keys
    local ssh_dir="${HOME_BASE}/$username/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"
    
    run_command mkdir -p "$ssh_dir"
    safe_write_file "$public_key $key_comment" "$auth_keys" "600"
    run_command chown -R "$username:$username" "$ssh_dir"
    run_command chmod 700 "$ssh_dir"
    
    # Select and assign sudo privileges
    select_sudo_privileges "$username"
    
    echo ""
    echo "User $username created successfully!"
    echo ""
    echo "SECURITY REMINDER: Always protect SSH private keys with a strong passphrase."
    
    read -p "Press Enter to continue..."
    echo ""
}

# Function to delete a user
delete_user() {
    echo "=== Delete User ==="
    echo ""
    
    read -p "Enter the username to delete: " username
    
    if ! id -u "$username" > /dev/null 2>&1; then
        echo "User $username does not exist."
        read -p "Press Enter to continue..."
        return
    fi
    
    # Prevent deleting root or system users
    local uid
    uid=$(id -u "$username")
    if [ "$uid" -lt 1000 ]; then
        echo "Cannot delete system user $username (UID $uid < 1000)."
        read -p "Press Enter to continue..."
        return
    fi
    
    echo ""
    echo "WARNING: This will permanently delete user $username and their home directory."
    read -p "Are you sure? Type 'yes' to confirm: " confirm
    
    if [ "$confirm" == "yes" ]; then
        # Backup authorized_keys before deletion
        backup_file "${HOME_BASE}/$username/.ssh/authorized_keys"
        
        run_command userdel -r "$username"
        
        # Clean up sudoers file
        remove_sudoers_file "$username"
        
        echo "User $username deleted."
        log_msg "User $username deleted along with sudoers file"
    else
        echo "Deletion cancelled."
    fi
    
    read -p "Press Enter to continue..."
    echo ""
}

# Function to review users
review_users() {
    echo "=== Review Users ==="
    echo ""
    echo "Users with home directories in ${HOME_BASE} and a login shell:"
    echo ""
    
    local users
    users=$(getent passwd | awk -F: -v home="^${HOME_BASE}/" '$6 ~ home && $7 !~ /nologin|false/ {print $1}')
    
    if [ -z "$users" ]; then
        echo "No users found."
    else
        for user in $users; do
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "User: $user"
            
            # Check sudo privileges
            local sudoers_file="/etc/sudoers.d/$user"
            if [ -f "$sudoers_file" ]; then
                echo "Sudo: $(cat "$sudoers_file")"
            else
                echo "Sudo: None configured"
            fi
            
            local auth_keys="${HOME_BASE}/$user/.ssh/authorized_keys"
            if [ -s "$auth_keys" ]; then
                echo "SSH Keys:"
                local key_num=1
                while read -r line; do
                    local key_type key_data comment
                    key_type=$(echo "$line" | awk '{print $1}')
                    key_data=$(echo "$line" | awk '{print $2}')
                    comment=$(echo "$line" | cut -d' ' -f3-)
                    echo "  $key_num) Type: $key_type"
                    echo "     Key: ${key_data:0:30}...${key_data: -10}"
                    echo "     Comment: $comment"
                    ((key_num++))
                done < "$auth_keys"
            else
                echo "SSH Keys: None"
            fi
            echo ""
        done
    fi
    
    read -p "Press Enter to continue..."
    echo ""
}

# Function to add a new SSH key for a user
add_key() {
    echo "=== Add New SSH Key ==="
    echo ""
    
    readarray -t users_array < <(getent passwd | awk -F: -v home="^${HOME_BASE}/" '$6 ~ home && $7 !~ /nologin|false/ {print $1}')
    
    if [ ${#users_array[@]} -eq 0 ]; then
        echo "No users found."
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    echo "Select a user:"
    selected_user=$(select_user "Enter number: " "${users_array[@]}")
    if [ $? -ne 0 ]; then
        return
    fi
    
    local user="$selected_user"
    echo ""
    echo "Selected user: $user"
    
    local ssh_dir="${HOME_BASE}/$user/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"
    
    # Ensure .ssh directory exists
    if [ ! -d "$ssh_dir" ]; then
        run_command mkdir -p "$ssh_dir"
        run_command chown "$user:$user" "$ssh_dir"
        run_command chmod 700 "$ssh_dir"
    fi
    
    # Ensure authorized_keys file exists
    if [ ! -f "$auth_keys" ]; then
        run_command touch "$auth_keys"
        run_command chown "$user:$user" "$auth_keys"
        run_command chmod 600 "$auth_keys"
    fi
    
    # Obtain the new key
    new_key=$(get_public_key)
    if [ $? -ne 0 ] || [ -z "$new_key" ]; then
        echo "Failed to obtain a valid public key."
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    # Extract just the key data for comparison (handles keys with or without comments)
    local new_key_data
    new_key_data=$(echo "$new_key" | awk '{print $2}')
    
    # Check for duplicate key (search for the key data anywhere in the file)
    if grep -qF "$new_key_data" "$auth_keys" 2>/dev/null; then
        echo "This key already exists for $user. Not adding duplicate."
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    read -p "Enter a comment for the new key: " new_comment
    new_comment=$(sanitize_comment "$new_comment")
    new_comment="$new_comment - Added on $(date +%Y-%m-%d)"
    
    # Backup before modification
    backup_file "$auth_keys"
    
    local new_line="$new_key $new_comment"
    
    if $DRY_RUN; then
        echo "Dry run: Would append key to $auth_keys"
    else
        safe_append_file "$new_line" "$auth_keys"
        echo "New key added successfully."
        echo ""
        echo "SECURITY REMINDER: Always protect SSH private keys with a strong passphrase."
    fi
    
    read -p "Press Enter to continue..."
    echo ""
}

# Function to revoke an SSH key
revoke_key() {
    echo "=== Revoke SSH Key ==="
    echo ""
    
    readarray -t users_array < <(getent passwd | awk -F: -v home="^${HOME_BASE}/" '$6 ~ home && $7 !~ /nologin|false/ {print $1}')
    
    if [ ${#users_array[@]} -eq 0 ]; then
        echo "No users found."
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    echo "Select a user:"
    selected_user=$(select_user "Enter number: " "${users_array[@]}")
    if [ $? -ne 0 ]; then
        return
    fi
    
    local user="$selected_user"
    echo ""
    echo "Selected user: $user"
    
    local auth_keys="${HOME_BASE}/$user/.ssh/authorized_keys"
    
    if [ ! -s "$auth_keys" ]; then
        echo "No SSH keys found for $user."
        read -p "Press Enter to continue..."
        return
    fi
    
    echo ""
    echo "SSH Keys for $user:"
    local i=1
    local key_count=0
    while read -r line; do
        local key_type key_data comment
        key_type=$(echo "$line" | awk '{print $1}')
        key_data=$(echo "$line" | awk '{print $2}')
        comment=$(echo "$line" | cut -d' ' -f3-)
        echo "$i. [$key_type] ${key_data:0:20}... - $comment"
        ((i++))
        ((key_count++))
    done < "$auth_keys"
    
    echo ""
    read -p "Select a key to revoke (1-$key_count): " key_num
    
    if ! [[ "$key_num" =~ ^[0-9]+$ ]] || [ "$key_num" -lt 1 ] || [ "$key_num" -gt "$key_count" ]; then
        echo "Invalid selection."
        read -p "Press Enter to continue..."
        return
    fi
    
    echo ""
    echo "Key to revoke:"
    sed -n "${key_num}p" "$auth_keys"
    echo ""
    read -p "Are you sure you want to revoke this key? (yes/no): " confirm
    
    if [ "$confirm" == "yes" ]; then
        backup_file "$auth_keys"
        
        if $DRY_RUN; then
            echo "Dry run: Would remove line $key_num from $auth_keys"
        else
            sed -i "${key_num}d" "$auth_keys"
            echo "Key revoked successfully."
        fi
    else
        echo "Revocation cancelled."
    fi
    
    read -p "Press Enter to continue..."
    echo ""
}

# Function to rotate an SSH key
rotate_key() {
    echo "=== Rotate SSH Key ==="
    echo ""
    
    readarray -t users_array < <(getent passwd | awk -F: -v home="^${HOME_BASE}/" '$6 ~ home && $7 !~ /nologin|false/ {print $1}')
    
    if [ ${#users_array[@]} -eq 0 ]; then
        echo "No users found."
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    echo "Select a user:"
    selected_user=$(select_user "Enter number: " "${users_array[@]}")
    if [ $? -ne 0 ]; then
        return
    fi
    
    local user="$selected_user"
    echo ""
    echo "Selected user: $user"
    
    local auth_keys="${HOME_BASE}/$user/.ssh/authorized_keys"
    
    if [ ! -s "$auth_keys" ]; then
        echo "No SSH keys found for $user."
        read -p "Press Enter to continue..."
        return
    fi
    
    echo ""
    echo "SSH Keys for $user:"
    local i=1
    local key_count=0
    while read -r line; do
        local key_type key_data comment
        key_type=$(echo "$line" | awk '{print $1}')
        key_data=$(echo "$line" | awk '{print $2}')
        comment=$(echo "$line" | cut -d' ' -f3-)
        echo "$i. [$key_type] ${key_data:0:20}... - $comment"
        ((i++))
        ((key_count++))
    done < "$auth_keys"
    
    echo ""
    read -p "Select a key to rotate (1-$key_count): " key_num
    
    if ! [[ "$key_num" =~ ^[0-9]+$ ]] || [ "$key_num" -lt 1 ] || [ "$key_num" -gt "$key_count" ]; then
        echo "Invalid selection."
        read -p "Press Enter to continue..."
        return
    fi
    
    # Obtain the new key
    new_key=$(get_public_key)
    if [ $? -ne 0 ] || [ -z "$new_key" ]; then
        echo "Failed to obtain a valid public key."
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    read -p "Enter a comment for the new key: " new_comment
    new_comment=$(sanitize_comment "$new_comment")
    new_comment="$new_comment - Rotated on $(date +%Y-%m-%d)"
    
    local new_line="$new_key $new_comment"
    
    backup_file "$auth_keys"
    
    if $DRY_RUN; then
        echo "Dry run: Would replace line $key_num in $auth_keys"
    else
        # Use a temp file approach to avoid sed delimiter issues
        local temp_file
        temp_file=$(mktemp)
        awk -v line="$key_num" -v replacement="$new_line" 'NR==line{print replacement; next} {print}' "$auth_keys" > "$temp_file"
        mv "$temp_file" "$auth_keys"
        chown "$user:$user" "$auth_keys"
        chmod 600 "$auth_keys"
        
        echo "Key rotated successfully."
        echo ""
        echo "SECURITY REMINDER: Always protect SSH private keys with a strong passphrase."
    fi
    
    read -p "Press Enter to continue..."
    echo ""
}

# Function to modify sudo privileges for existing user
modify_sudo() {
    echo "=== Modify Sudo Privileges ==="
    echo ""
    
    readarray -t users_array < <(getent passwd | awk -F: -v home="^${HOME_BASE}/" '$6 ~ home && $7 !~ /nologin|false/ {print $1}')
    
    if [ ${#users_array[@]} -eq 0 ]; then
        echo "No users found."
        read -p "Press Enter to continue..." < /dev/tty
        return
    fi
    
    echo "Select a user:"
    selected_user=$(select_user "Enter number: " "${users_array[@]}")
    if [ $? -ne 0 ]; then
        return
    fi
    
    local user="$selected_user"
    echo ""
    echo "Selected user: $user"
    
    local sudoers_file="/etc/sudoers.d/$user"
    if [ -f "$sudoers_file" ]; then
        echo "Current sudo configuration:"
        cat "$sudoers_file"
    else
        echo "No sudo configuration currently exists."
    fi
    
    echo ""
    read -p "Do you want to change the sudo configuration? (yes/no): " confirm
    
    if [ "$confirm" == "yes" ]; then
        # Remove existing sudoers file
        remove_sudoers_file "$user"
        # Set new privileges
        select_sudo_privileges "$user"
        echo "Sudo privileges updated."
    else
        echo "No changes made."
    fi
    
    read -p "Press Enter to continue..."
    echo ""
}

# Function to show help
show_help() {
    echo "=== Help ==="
    echo ""
    echo "User Management Script v2.0"
    echo ""
    echo "Menu Options:"
    echo "  1. Add a new user     - Create user with SSH key and configurable sudo"
    echo "  2. Delete a user      - Remove user, home directory, and sudoers file"
    echo "  3. Review users       - List all users with their SSH keys and sudo config"
    echo "  4. Add SSH key        - Add a new key to an existing user"
    echo "  5. Revoke SSH key     - Remove a specific key from a user"
    echo "  6. Rotate SSH key     - Replace an existing key with a new one"
    echo "  7. Modify sudo        - Change sudo privileges for existing user"
    echo "  8. Show help          - Display this message"
    echo "  9. Exit               - Quit the script"
    echo ""
    echo "Command Line Options:"
    echo "  --dry-run             - Simulate actions without making changes"
    echo ""
    echo "Configuration Variables (edit in script):"
    echo "  HOME_BASE             - Base directory for home folders (default: /home)"
    echo "  ALLOW_RSA_KEYS        - Enable legacy RSA key support (default: false)"
    echo ""
    echo "Sudo Privilege Levels:"
    echo "  None      - No sudo access"
    echo "  Standard  - Sudo with password required"
    echo "  NOPASSWD  - Sudo without password (use sparingly)"
    echo "  Limited   - NOPASSWD for specific commands only"
    echo ""
    echo "Backups are stored in: $BACKUP_DIR"
    echo "Logs are written to: $LOG_FILE"
    echo ""
    read -p "Press Enter to continue..."
    echo ""
}

# Main loop with menu
while true; do
    echo "╔════════════════════════════════════════╗"
    echo "║     User Management Script v2.0        ║"
    echo "╚════════════════════════════════════════╝"
    
    if $DRY_RUN; then
        echo "⚠️  DRY RUN MODE - No changes will be made"
    fi
    
    echo ""
    echo "  1. Add a new user"
    echo "  2. Delete a user"
    echo "  3. Review users"
    echo "  4. Add a new SSH key for a user"
    echo "  5. Revoke a user's SSH key"
    echo "  6. Rotate a user's SSH key"
    echo "  7. Modify user's sudo privileges"
    echo "  8. Show help"
    echo "  9. Exit"
    echo ""
    read -p "Enter your choice (1-9): " choice
    echo ""
    
    case "$choice" in
        1) add_user ;;
        2) delete_user ;;
        3) review_users ;;
        4) add_key ;;
        5) revoke_key ;;
        6) rotate_key ;;
        7) modify_sudo ;;
        8) show_help ;;
        9) echo "Goodbye!"; exit 0 ;;
        *) 
            echo "Invalid choice. Please enter a number between 1 and 9."
            read -p "Press Enter to continue..."
            echo ""
            ;;
    esac
done
