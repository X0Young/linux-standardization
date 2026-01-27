# Rocky Linux Standardization Script

This repository contains a **Bash script (`standard_v9.sh`)** that applies **basic system configurations and security hardening** for Rocky Linux servers (tested on Rocky 8/9).

The script includes SSH hardening, firewall configuration, password policy enforcement, login session timeout, history logging improvements, and account lock policies.

---

## Features

### 1. SSH Configuration
- Changes the default SSH port from **22 to 24477**.
- Applies SELinux policy changes for the new SSH port.
- Restarts the `sshd` service to apply changes.

### 2. `su` Command Access Restriction
- Restricts `su` command usage to users in the **wheel** group.
- Adjusts `/bin/su` permissions to **4750**.
- Adds the current user (`$username`) to the **wheel** group.

### 3. Password Complexity Policy
- Enforces minimum password length (`minlen = 8`).
- Requires at least one digit and one special character.
- Updates `/etc/security/pwquality.conf`.

### 4. Firewall (firewalld) Configuration
- Sets the default zone to **drop**.
- Opens the custom SSH port **24477/tcp**.
- Reloads the firewall rules.

### 5. Login Session & History
- Sets an automatic logout timeout of **10 minutes (TMOUT=600)** for inactive sessions.
- Increases shell history size to **10,000** entries.
- Enables history timestamps (`HISTTIMEFORMAT`).

### 6. FailLock (Account Lockout Policy)
- Enables `faillock` to lock accounts after 3 failed login attempts.
- Configures unlock time to **600 seconds**.

---

## Usage

1. Clone this repository:
   ```bash
   git clone https://github.com/X0Young/rocky-standardization.git
   cd rocky-standardization
