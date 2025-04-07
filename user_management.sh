#!/bin/bash
# Requires Bash 4 or higher

# Configurable variables
HOME_BASE="/home"
LOG_FILE="/var/log/user_management.log"

# Ensure LOG_FILE exists and is writable
touch "$LOG_FILE" 2>/dev/null
if [ $? -ne 0 ]; then
  LOG_FILE="/tmp/user_management.log"
  touch "$LOG_FILE" 2>/dev/null
fi

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
      log_msg "Error: Command failed: $*"
      echo "Error: Command failed: $*"
      exit $status
    fi
  fi
}

# Function to execute shell commands that require redirection/pipes
run_command_shell() {
  log_msg "Executing (shell): $1"
  if $DRY_RUN; then
    echo "Dry run: $1"
  else
    bash -c "$1"
    local status=$?
    if [ $status -ne 0 ]; then
      log_msg "Error: Command failed: $1"
      echo "Error: Command failed: $1"
      exit $status
    fi
  fi
}

# Function to escape single quotes in strings
escape_single_quotes() {
  echo "$1" | sed "s/'/'\\\\''/g"
}

# Regular expression for allowed public keys (Ed25519 or ECDSA)
PUBLIC_KEY_REGEX='^(ssh-ed25519|ecdsa-sha2-(nistp256|nistp384|nistp521))[[:space:]]+[A-Za-z0-9+/=]+$'

# Helper function to obtain a public key either manually or from GitHub.
# All interactive prompts are directed to /dev/tty so they aren’t captured in command substitution.
get_public_key() {
  local method
  while true; do
    echo "Choose how to provide the SSH key:" > /dev/tty
    echo "  1) Paste key manually (enter the key directly)" > /dev/tty
    echo "  2) Fetch from GitHub (retrieve your public keys from your GitHub account)" > /dev/tty
    read -p "Enter your choice (1 or 2): " method < /dev/tty
    if [[ "$method" == "1" || "$method" == "2" ]]; then
      break
    fi
    echo "Invalid selection." > /dev/tty
  done

  if [ "$method" == "1" ]; then
    while true; do
      read -p "Enter the public key (allowed types: ssh-ed25519, ecdsa-sha2-nistp256, ecdsa-sha2-nistp384, ecdsa-sha2-nistp521; key type and key only, without comment): " pub_key < /dev/tty
      if [[ $pub_key =~ $PUBLIC_KEY_REGEX ]]; then
        echo "$pub_key"
        return 0
      else
        echo "Invalid key format." > /dev/tty
      fi
    done
  else
    if ! command -v curl > /dev/null; then
      echo "Error: curl is required for fetching keys from GitHub." >&2
      return 1
    fi
    read -p "Enter the GitHub username: " github_user < /dev/tty
    keys=$(curl -s "https://github.com/$github_user.keys")
    if [ -z "$keys" ]; then
      echo "No keys found for GitHub user $github_user." >&2
      return 1
    fi
    IFS=$'\n' read -rd '' -a key_array <<<"$keys"
    if [ ${#key_array[@]} -gt 1 ]; then
      echo "Multiple keys found for GitHub user $github_user:" > /dev/tty
      local i=1
      for key in "${key_array[@]}"; do
        echo "  $i) $key" > /dev/tty
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
    # Remove any existing comment – keep only the key type and key.
    cleaned_key=$(echo "$selected_key" | awk '{print $1, $2}')
    if [[ $cleaned_key =~ $PUBLIC_KEY_REGEX ]]; then
      echo "$cleaned_key"
      return 0
    else
      echo "Fetched key is invalid." >&2
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
    echo "$i. $user"
    user_map[$i]="$user"
    ((i++))
  done
  read -p "$prompt" user_num
  if ! [[ "$user_num" =~ ^[0-9]+$ ]] || [ "$user_num" -lt 1 ] || [ "$user_num" -ge "$i" ]; then
    echo "Invalid selection."
    read -p "Press Enter to continue..."
    return 1
  fi
  echo "${user_map[$user_num]}"
  return 0
}

# Function to add a new user
add_user() {
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

  # Obtain the public key using the helper function
  public_key=$(get_public_key)
  if [ $? -ne 0 ] || [ -z "$public_key" ]; then
    echo "Failed to obtain a valid public key."
    read -p "Press Enter to continue..."
    return
  fi

  read -p "Enter a comment for the key (e.g., 'John’s laptop'): " key_comment
  # Trim trailing whitespace from the comment
  key_comment=$(echo "$key_comment" | sed 's/[[:space:]]*$//')
  key_comment="$key_comment - Added on $(date +%Y-%m-%d)"

  if id -u "$username" > /dev/null 2>&1; then
    echo "User $username already exists."
  else
    run_command useradd -m -s /bin/bash "$username"
    run_command passwd -l "$username"
    run_command usermod -aG sudo "$username"
    run_command mkdir -p "${HOME_BASE}/$username/.ssh"
    # Escape single quotes in public_key and key_comment
    escaped_public_key=$(escape_single_quotes "$public_key")
    escaped_key_comment=$(escape_single_quotes "$key_comment")
    run_command_shell "echo '$escaped_public_key $escaped_key_comment' > ${HOME_BASE}/$username/.ssh/authorized_keys"
    run_command chown -R "$username:$username" "${HOME_BASE}/$username/.ssh"
    run_command chmod 700 "${HOME_BASE}/$username/.ssh"
    run_command chmod 600 "${HOME_BASE}/$username/.ssh/authorized_keys"
    run_command_shell "echo '$username ALL=(ALL) NOPASSWD: ALL' | tee /etc/sudoers.d/$username > /dev/null"
    run_command chmod 440 "/etc/sudoers.d/$username"
    echo "User $username created successfully!"
    echo "IMPORTANT SECURITY NOTICE: ALWAYS secure your SSH private key with a strong passphrase. Failure to do so may leave your system vulnerable!"
  fi
  read -p "Press Enter to continue..."
  echo ""
  echo ""
}

# Function to delete a user
delete_user() {
  echo "=== Delete User ==="
  echo "Please specify the user to delete:"
  echo ""
  read -p "Enter the username to delete: " username
  if ! id -u "$username" > /dev/null 2>&1; then
    echo "User $username does not exist."
  else
    read -p "Are you sure you want to delete $username? (yes/no): " confirm
    if [ "$confirm" == "yes" ]; then
      run_command userdel -r "$username"
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
review_users() {
  echo "=== Review Users ==="
  echo "Listing all users with home directories in ${HOME_BASE} and a login shell:"
  echo ""
  # Get users with home in HOME_BASE and a login shell
  users=$(getent passwd | awk -F: -v home="^${HOME_BASE}/" '$6 ~ home && $7 !~ /nologin|false/ {print $1}')
  if [ -z "$users" ]; then
    echo "No users found."
  else
    for user in $users; do
      echo "User: $user"
      if [ -f "${HOME_BASE}/$user/.ssh/authorized_keys" ]; then
        echo "SSH Keys:"
        while read -r line; do
          key=$(echo "$line" | cut -d' ' -f1,2)
          comment=$(echo "$line" | cut -d' ' -f3-)
          echo " Key: $key"
          echo " Comment: $comment"
        done < "${HOME_BASE}/$user/.ssh/authorized_keys"
      else
        echo " No SSH keys found."
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
add_key() {
  echo "=== Add New SSH Key for User ==="
  echo "Select a user to add an SSH key:"
  echo ""
  readarray -t users_array < <(getent passwd | awk -F: -v home="^${HOME_BASE}/" '$6 ~ home && $7 !~ /nologin|false/ {print $1}')
  if [ ${#users_array[@]} -eq 0 ]; then
    echo "No users found."
    read -p "Press Enter to continue..."
    echo ""
    echo ""
    return
  fi
  selected_user=$(select_user "Select a user by number: " "${users_array[@]}")
  if [ $? -ne 0 ]; then
    return
  fi
  user="$selected_user"
  echo ""
  echo "Selected user: $user"
  # Ensure .ssh directory exists
  if [ ! -d "${HOME_BASE}/$user/.ssh" ]; then
    run_command mkdir -p "${HOME_BASE}/$user/.ssh"
    run_command chown "$user:$user" "${HOME_BASE}/$user/.ssh"
    run_command chmod 700 "${HOME_BASE}/$user/.ssh"
  fi
  authorized_keys="${HOME_BASE}/$user/.ssh/authorized_keys"
  # Ensure authorized_keys file exists
  if [ ! -f "$authorized_keys" ]; then
    run_command touch "$authorized_keys"
    run_command chown "$user:$user" "$authorized_keys"
    run_command chmod 600 "$authorized_keys"
  fi

  # Obtain the new key via helper function
  new_key=$(get_public_key)
  if [ $? -ne 0 ] || [ -z "$new_key" ]; then
    echo "Failed to obtain a valid public key."
    read -p "Press Enter to continue..."
    return
  fi

  # Check for duplicate key
  if grep -q "^$new_key " "$authorized_keys"; then
    echo "This key already exists for $user. Not adding duplicate."
    read -p "Press Enter to continue..."
    return
  fi

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
    echo "IMPORTANT SECURITY NOTICE: ALWAYS secure your SSH private key with a strong passphrase. Failure to do so may leave your system vulnerable!"
  fi
  read -p "Press Enter to continue..."
  echo ""
  echo ""
}

# Function to revoke an SSH key
revoke_key() {
  echo "=== Revoke SSH Key ==="
  echo "Select a user to revoke an SSH key:"
  echo ""
  readarray -t users_array < <(getent passwd | awk -F: -v home="^${HOME_BASE}/" '$6 ~ home && $7 !~ /nologin|false/ {print $1}')
  if [ ${#users_array[@]} -eq 0 ]; then
    echo "No users found."
    read -p "Press Enter to continue..."
    echo ""
    echo ""
    return
  fi
  selected_user=$(select_user "Select a user by number: " "${users_array[@]}")
  if [ $? -ne 0 ]; then
    return
  fi
  user="$selected_user"
  echo ""
  echo "Selected user: $user"
  authorized_keys="${HOME_BASE}/$user/.ssh/authorized_keys"
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
      run_command sed -i "${key_num}d" "$authorized_keys"
      echo "Key revoked successfully."
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
rotate_key() {
  echo "=== Rotate SSH Key ==="
  echo "Select a user to rotate an SSH key:"
  echo ""
  readarray -t users_array < <(getent passwd | awk -F: -v home="^${HOME_BASE}/" '$6 ~ home && $7 !~ /nologin|false/ {print $1}')
  if [ ${#users_array[@]} -eq 0 ]; then
    echo "No users found."
    read -p "Press Enter to continue..."
    echo ""
    echo ""
    return
  fi
  selected_user=$(select_user "Select a user by number: " "${users_array[@]}")
  if [ $? -ne 0 ]; then
    return
  fi
  user="$selected_user"
  echo ""
  echo "Selected user: $user"
  authorized_keys="${HOME_BASE}/$user/.ssh/authorized_keys"
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
    # Obtain the new key via helper function
    new_key=$(get_public_key)
    if [ $? -ne 0 ] || [ -z "$new_key" ]; then
      echo "Failed to obtain a valid public key."
      read -p "Press Enter to continue..."
      return
    fi
    read -p "Enter a comment for the new key (avoid using #): " new_comment
    # Trim trailing whitespace from the comment
    new_comment=$(echo "$new_comment" | sed 's/[[:space:]]*$//')
    new_comment="$new_comment - Rotated on $(date +%Y-%m-%d)"
    new_line="$new_key $new_comment"
    run_command sed -i "${key_num}s!.*!$new_line!" "$authorized_keys"
    echo "Key rotated successfully."
    echo "IMPORTANT SECURITY NOTICE: ALWAYS secure your SSH private key with a strong passphrase. Failure to do so may leave your system vulnerable!"
  else
    echo "No SSH keys found for $user."
  fi
  read -p "Press Enter to continue..."
  echo ""
  echo ""
}

# Function to show help
show_help() {
  echo "=== Help ==="
  echo "User Management Script Help:"
  echo " 1. Add a new user: Create a user with a public key."
  echo " 2. Delete a user: Remove a user and their home directory."
  echo " 3. Review users: List all users or check a specific user’s details."
  echo " 4. Add a new SSH key for a user: Append a new SSH key to an existing user's authorized_keys."
  echo " 5. Revoke a user’s SSH key: Remove a specific key."
  echo " 6. Rotate a user’s SSH key: Replace an existing key with a new one."
  echo " 7. Show help: Display this message."
  echo " 8. Exit: Quit the script."
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
  echo " 1. Add a new user"
  echo " 2. Delete a user"
  echo " 3. Review users"
  echo " 4. Add a new SSH key for a user"
  echo " 5. Revoke a user's SSH key"
  echo " 6. Rotate a user's SSH key"
  echo " 7. Show help"
  echo " 8. Exit"
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
    *) echo "Invalid choice. Please enter a number between 1 and 8."
       read -p "Press Enter to continue..."
       echo ""
       echo "" ;;
  esac
done
