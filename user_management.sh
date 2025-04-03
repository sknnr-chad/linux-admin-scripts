#!/bin/bash
# Requires Bash 4 or higher

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Check for dry run mode from command line
DRY_RUN=false
for arg in "$@"; do
    if [ "$arg" == "--dry-run" ]; then
        DRY_RUN=true
    fi
done

# Function to execute or simulate commands with error checking
function run_command {
    if $DRY_RUN; then
        echo "Dry run: $1"
    else
        eval "$1"
        if [ $? -ne 0 ]; then
            echo "Error: Command failed: $1"
            exit 1
        fi
    fi
}

# Function to escape single quotes in strings
function escape_single_quotes {
    echo "$1" | sed "s/'/'\\\\''/g"
}

# Regular expression for allowed public keys (Ed25519 or ECDSA)
PUBLIC_KEY_REGEX='^(ssh-ed25519|ecdsa-sha2-(nistp256|nistp384|nistp521))[[:space:]]+[A-Za-z0-9+/=]+$'

# Function to add a new user
function add_user {
    echo "=== Add New User ==="
    echo "Please provide the details for the new user:"
    echo ""
    while true; do
        read -p "Enter the new username (e.g., john_doe): " username
        if [[ $username =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
            break
        else
            echo "Invalid username. Use 1-32 alphanumeric characters, underscores, or hyphens."
        fi
    done

    while true; do
        read -p "Enter the public key (allowed types: ssh-ed25519, ecdsa-sha2-nistp256, ecdsa-sha2-nistp384, ecdsa-sha2-nistp521; key type and key only, without comment): " public_key
        if [[ $public_key =~ $PUBLIC_KEY_REGEX ]]; then
            break
        else
            echo "Invalid key. It must start with one of the allowed key types followed by the key, with no comment."
        fi
    done

    read -p "Enter a comment for the key (e.g., 'John’s laptop'): " key_comment
    # Trim trailing whitespace from the comment
    key_comment=$(echo "$key_comment" | sed 's/[[:space:]]*$//')
    key_comment="$key_comment - Added on $(date +%Y-%m-%d)"

    if id -u "$username" > /dev/null 2>&1; then
        echo "User $username already exists."
    else
        run_command "useradd -m -s /bin/bash '$username'"
        run_command "passwd -l '$username'"
        run_command "usermod -aG sudo '$username'"
        run_command "mkdir -p /home/$username/.ssh"
        # Escape single quotes in public_key and key_comment
        escaped_public_key=$(escape_single_quotes "$public_key")
        escaped_key_comment=$(escape_single_quotes "$key_comment")
        run_command "echo '$escaped_public_key $escaped_key_comment' > /home/$username/.ssh/authorized_keys"
        run_command "chown -R '$username':'$username' /home/$username/.ssh"
        run_command "chmod 700 /home/$username/.ssh"
        run_command "chmod 600 /home/$username/.ssh/authorized_keys"
        run_command "echo '$username ALL=(ALL) NOPASSWD: ALL' | tee /etc/sudoers.d/$username > /dev/null"
        run_command "chmod 440 /etc/sudoers.d/$username"
        echo "User $username created successfully!"
    fi
    read -p "Press Enter to continue..."
    echo ""
    echo ""
}

# Function to delete a user
function delete_user {
    echo "=== Delete User ==="
    echo "Please specify the user to delete:"
    echo ""
    read -p "Enter the username to delete: " username
    if ! id -u "$username" > /dev/null 2>&1; then
        echo "User $username does not exist."
    else
        read -p "Are you sure you want to delete $username? (yes/no): " confirm
        if [ "$confirm" == "yes" ]; then
            run_command "userdel -r '$username'"
            echo "User $username deleted."
        else
            echo "Deletion cancelled."
        fi
    fi
    read -p "Press Enter to continue..."
    echo ""
    echo ""
}

# Function to review users
function review_users {
    echo "=== Review Users ==="
    echo "Listing all users with home directories in /home and a login shell:"
    echo ""
    # Get users with home in /home and a login shell
    users=$(getent passwd | awk -F: '$6 ~ /^\/home\// && $7 !~ /nologin|false/ {print $1}')
    if [ -z "$users" ]; then
        echo "No users found."
    else
        for user in $users; do
            echo "User: $user"
            if [ -f "/home/$user/.ssh/authorized_keys" ]; then
                echo "SSH Keys:"
                while read -r line; do
                    key=$(echo "$line" | cut -d' ' -f1,2)
                    comment=$(echo "$line" | cut -d' ' -f3-)
                    echo "  Key: $key"
                    echo "  Comment: $comment"
                done < "/home/$user/.ssh/authorized_keys"
            else
                echo "  No SSH keys found."
            fi
            echo ""
        done
    fi
    echo "Review completed."
    read -p "Press Enter to continue..."
    echo ""
    echo ""
}

# Function to add a new SSH key for a user
function add_key {
    echo "=== Add New SSH Key for User ==="
    echo "Select a user to add an SSH key:"
    echo ""
    # Get users with home in /home and a login shell
    users=$(getent passwd | awk -F: '$6 ~ /^\/home\// && $7 !~ /nologin|false/ {print $1}')
    if [ -z "$users" ]; then
        echo "No users found."
        read -p "Press Enter to continue..."
        echo ""
        echo ""
        return
    fi
    i=1
    declare -A user_map
    for user in $users; do
        echo "$i. $user"
        user_map[$i]=$user
        ((i++))
    done
    read -p "Select a user by number: " user_num
    # Validate user selection
    if ! [[ "$user_num" =~ ^[0-9]+$ ]] || [ "$user_num" -lt 1 ] || [ "$user_num" -ge "$i" ]; then
        echo "Invalid selection."
        read -p "Press Enter to continue..."
        echo ""
        echo ""
        return
    fi
    user=${user_map[$user_num]}
    echo ""
    echo "Selected user: $user"
    # Check if .ssh directory exists, create if not
    if [ ! -d "/home/$user/.ssh" ]; then
        run_command "mkdir -p /home/$user/.ssh"
        run_command "chown $user:$user /home/$user/.ssh"
        run_command "chmod 700 /home/$user/.ssh"
    fi
    authorized_keys="/home/$user/.ssh/authorized_keys"
    # If authorized_keys doesn't exist, create it
    if [ ! -f "$authorized_keys" ]; then
        run_command "touch $authorized_keys"
        run_command "chown $user:$user $authorized_keys"
        run_command "chmod 600 $authorized_keys"
    fi
    # Prompt for new key
    while true; do
        read -p "Enter the new public key (allowed types: ssh-ed25519, ecdsa-sha2-nistp256, ecdsa-sha2-nistp384, ecdsa-sha2-nistp521; key type and key only, without comment): " new_key
        if [[ $new_key =~ $PUBLIC_KEY_REGEX ]]; then
            break
        else
            echo "Invalid key. It must start with one of the allowed key types followed by the key, with no comment."
        fi
    done
    read -p "Enter a comment for the new key (avoid using #): " new_comment
    # Trim trailing whitespace from the comment
    new_comment=$(echo "$new_comment" | sed 's/[[:space:]]*$//')
    new_comment="$new_comment - Rotated on $(date +%Y-%m-%d)"
    new_line="$new_key $new_comment"
    if $DRY_RUN; then
        echo "Dry run: Would append '$new_line' to $authorized_keys"
    else
        echo "$new_line" >> "$authorized_keys"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to add the new SSH key."
            exit 1
        fi
        echo "New key added successfully."
    fi
    read -p "Press Enter to continue..."
    echo ""
    echo ""
}

# Function to revoke an SSH key
function revoke_key {
    echo "=== Revoke SSH Key ==="
    echo "Select a user to revoke an SSH key:"
    echo ""
    # Get users with home in /home and a login shell
    users=$(getent passwd | awk -F: '$6 ~ /^\/home\// && $7 !~ /nologin|false/ {print $1}')
    if [ -z "$users" ]; then
        echo "No users found."
        read -p "Press Enter to continue..."
        echo ""
        echo ""
        return
    fi
    i=1
    declare -A user_map
    for user in $users; do
        echo "$i. $user"
        user_map[$i]=$user
        ((i++))
    done
    read -p "Select a user by number: " user_num
    # Validate user selection
    if ! [[ "$user_num" =~ ^[0-9]+$ ]] || [ "$user_num" -lt 1 ] || [ "$user_num" -ge "$i" ]; then
        echo "Invalid selection."
        read -p "Press Enter to continue..."
        echo ""
        echo ""
        return
    fi
    user=${user_map[$user_num]}
    echo ""
    echo "Selected user: $user"
    authorized_keys="/home/$user/.ssh/authorized_keys"
    if [ -f "$authorized_keys" ]; then
        echo "SSH Keys for $user:"
        i=1
        while read -r line; do
            echo "$i. $line"
            ((i++))
        done < "$authorized_keys"
        echo ""
        read -p "Select a key to revoke by number: " key_num
        if ! [[ "$key_num" =~ ^[0-9]+$ ]] || [ "$key_num" -lt 1 ] || [ "$key_num" -ge "$i" ]; then
            echo "Invalid selection."
            read -p "Press Enter to continue..."
            echo ""
            echo ""
            return
        fi
        echo ""
        echo "Selected key: $(sed -n "${key_num}p" "$authorized_keys")"
        read -p "Are you sure you want to revoke this key? (yes/no): " confirm
        if [ "$confirm" == "yes" ]; then
            if $DRY_RUN; then
                echo "Dry run: Would remove key $key_num from $authorized_keys"
            else
                run_command "sed -i \"${key_num}d\" \"$authorized_keys\""
                echo "Key revoked successfully."
            fi
        else
            echo "Revocation cancelled."
        fi
    else
        echo "No SSH keys found for $user."
    fi
    read -p "Press Enter to continue..."
    echo ""
    echo ""
}

# Function to rotate an SSH key with user guidance
function rotate_key {
    echo "=== Rotate SSH Key ==="
    echo "Select a user to rotate an SSH key:"
    echo ""
    # Get users with home in /home and a login shell
    users=$(getent passwd | awk -F: '$6 ~ /^\/home\// && $7 !~ /nologin|false/ {print $1}')
    if [ -z "$users" ]; then
        echo "No users found."
        read -p "Press Enter to continue..."
        echo ""
        echo ""
        return
    fi
    i=1
    declare -A user_map
    for user in $users; do
        echo "$i. $user"
        user_map[$i]=$user
        ((i++))
    done
    read -p "Select a user by number: " user_num
    # Validate user selection
    if ! [[ "$user_num" =~ ^[0-9]+$ ]] || [ "$user_num" -lt 1 ] || [ "$user_num" -ge "$i" ]; then
        echo "Invalid selection."
        read -p "Press Enter to continue..."
        echo ""
        echo ""
        return
    fi
    user=${user_map[$user_num]}
    echo ""
    echo "Selected user: $user"
    authorized_keys="/home/$user/.ssh/authorized_keys"
    if [ -f "$authorized_keys" ]; then
        echo "SSH Keys for $user:"
        i=1
        while read -r line; do
            echo "$i. $line"
            ((i++))
        done < "$authorized_keys"
        echo ""
        read -p "Select a key to rotate by number: " key_num
        if ! [[ "$key_num" =~ ^[0-9]+$ ]] || [ "$key_num" -lt 1 ] || [ "$key_num" -ge "$i" ]; then
            echo "Invalid selection."
            read -p "Press Enter to continue..."
            echo ""
            echo ""
            return
        fi
        # Prompt and validate new key
        while true; do
            read -p "Enter the new public key (allowed types: ssh-ed25519, ecdsa-sha2-nistp256, ecdsa-sha2-nistp384, ecdsa-sha2-nistp521; key type and key only, without comment): " new_key
            if [[ $new_key =~ $PUBLIC_KEY_REGEX ]]; then
                break
            else
                echo "Invalid key. It must start with one of the allowed key types followed by the key, with no comment."
            fi
        done
        read -p "Enter a comment for the new key (avoid using #): " new_comment
        # Trim trailing whitespace from the comment
        new_comment=$(echo "$new_comment" | sed 's/[[:space:]]*$//')
        new_comment="$new_comment - Rotated on $(date +%Y-%m-%d)"
        new_line="$new_key $new_comment"
        if $DRY_RUN; then
            echo "Dry run: Would replace line $key_num in $authorized_keys with '$new_line'"
        else
            # Use "!" as the delimiter for sed to avoid issues with common characters
            run_command "sed -i \"${key_num}s!.*!$new_line!\" \"$authorized_keys\""
            echo "Key rotated successfully."
        fi
    else
        echo "No SSH keys found for $user."
    fi
    read -p "Press Enter to continue..."
    echo ""
    echo ""
}

# Function to show help
function show_help {
    echo "=== Help ==="
    echo "User Management Script Help:"
    echo "  1. Add a new user: Create a user with a public key."
    echo "  2. Delete a user: Remove a user and their home directory."
    echo "  3. Review users: List all users or check a specific user’s details."
    echo "  4. Add a new SSH key for a user: Append a new SSH key to an existing user's authorized_keys."
    echo "  5. Revoke a user’s SSH key: Remove a specific key."
    echo "  6. Rotate a user’s SSH key: Replace an existing key with a new one."
    echo "  7. Show help: Display this message."
    echo "  8. Exit: Quit the script."
    echo "Tip: Use --dry-run when running the script to simulate actions."
    echo ""
    read -p "Press Enter to continue..."
    echo ""
    echo ""
}

# Main loop with menu
while true; do
    echo "=== User Management Menu ==="
    if $DRY_RUN; then
        echo "Dry run mode is active. No changes will be made."
    fi
    echo "Please select an action:"
    echo "  1. Add a new user"
    echo "  2. Delete a user"
    echo "  3. Review users"
    echo "  4. Add a new SSH key for a user"
    echo "  5. Revoke a user's SSH key"
    echo "  6. Rotate a user's SSH key"
    echo "  7. Show help"
    echo "  8. Exit"
    echo ""
    read -p "Enter the number of your choice: " choice
    echo ""
    case "$choice" in
        1) add_user ;;
        2) delete_user ;;
        3) review_users ;;
        4) add_key ;;
        5) revoke_key ;;
        6) rotate_key ;;
        7) show_help ;;
        8) echo "Goodbye!"; exit 0 ;;
        *) echo "Invalid choice. Please enter a number between 1 and 8."; read -p "Press Enter to continue..."; echo ""; echo "" ;;
    esac
done
