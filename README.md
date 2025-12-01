# Proxmox-VE-Tools
Scripts for Proxmox VE deployment

## cluster-ssh-copy.sh

This script copies a specified file to multiple hosts listed in a `host.txt` file.

### Usage

```bash
./cluster-ssh-copy.sh <host_list_file> <source_file_path>
```

- `<host_list_file>`: Path to the file containing a list of hostnames (one per line).
- `<source_file_path>`: Path to the file to be copied (e.g., `/etc/multipath.conf`).

### Example

1. Create a `host.txt` file with the target hostnames:

   ```
   host1.example.com
   host2.example.com
   192.168.1.100
   ```

2. To copy `/etc/multipath.conf` to all hosts listed in `host.txt`:

   ```bash
   ./cluster-ssh-copy.sh host.txt /etc/multipath.conf
   ```

## cluster-ssh-exec.sh

This script executes commands from a specified file on multiple hosts listed in a `host.txt` file.

### Usage

```bash
./cluster-ssh-exec.sh <host_list_file> <commands_file_path>
```

- `<host_list_file>`: Path to the file containing a list of hostnames (one per line).
- `<commands_file_path>`: Path to the file containing commands to be executed on each host.

### Example

1. Create a `host.txt` file with the target hostnames (e.g., `localhost` for testing):

   ```
   host1.example.com
   host2.example.com
   192.168.1.100
   ```

2. Create a `commands_to_exec.txt` file with the commands to run:

   ```bash
   date > /tmp/date.txt
   echo "Date written to /tmp/date.txt on $(hostname)"
   ```

3. To execute the commands in `commands_to_exec.txt` on all hosts listed in `host.txt`:

   ```bash
   ./cluster-ssh-exec.sh host.txt commands_to_exec.txt
   ```
