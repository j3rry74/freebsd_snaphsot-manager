Here is the English translation of the README file:

---

# Snapshot Manager

Intelligent ZFS snapshot manager for FreeNAS/FreeBSD with **cold storage** support.

## Features

* **Smart snapshots**: Creates missed snapshots if the NAS was powered off
* **Flexible policies**: daily, weekly, monthly, quarterly
* **Automatic retention**: Configurable cleanup of old snapshots
* **Dry-run mode**: Simulation without making changes
* **Detailed logs**: Full operation tracking

## Installation

### Quick installation

```bash
# Copy files to the NAS
scp -r snapshot-manager/ root@nas:/tmp/

# On the NAS, run the installer
ssh root@nas
cd /tmp/snapshot-manager
chmod +x install.sh
./install.sh
```

### Manual installation

```bash
# Create the directory
mkdir -p /root/snapshot-manager

# Copy files
cp snapshot-manager.sh /root/snapshot-manager/
cp config.txt /root/snapshot-manager/

# Permissions
chmod 755 /root/snapshot-manager/snapshot-manager.sh
chmod 644 /root/snapshot-manager/config.txt

# Symbolic link (optional)
ln -s /root/snapshot-manager/snapshot-manager.sh /usr/local/bin/snapshot-manager

# Cron job (daily execution at 10:00 PM)
echo "0 22 * * * /root/snapshot-manager/snapshot-manager.sh run >> /var/log/snapshot-manager.log 2>&1" | crontab -
```

## Configuration

Edit `/root/snapshot-manager/config.txt`:

```ini
# Automatic deletion of expired snapshots
AUTO_DELETE=no  # 'yes' to enable

# Format: DATASET:<name>:<policy>:<retention>:<unit>:<enabled>
DATASET:mypool/Documents:weekly:30:days:yes
DATASET:mypool/Photos:monthly:12:months:yes
```

### Available policies

| Policy      | Snapshot format      | Example                                       |
| ----------- | -------------------- | --------------------------------------------- |
| `daily`     | `@daily_YYYY-MM-DD`  | `@daily_2024-12-26`                           |
| `weekly`    | `@weekly_YYYY-MM-DD` | `@weekly_2024-12-23` (Monday date)            |
| `monthly`   | `@monthly_YYYY-MM`   | `@monthly_2024-12`                            |
| `quarterly` | `@quarterly_YYYY-MM` | `@quarterly_2024-10` (months: 01, 04, 07, 10) |

### Retention units

* `days` : days
* `months` : months
* `years` : years

## Usage

### Main commands

```bash
# Show help
snapshot-manager help

# View status of all datasets
snapshot-manager status

# List snapshots
snapshot-manager list
snapshot-manager list mypool/Documents

# Run (creation + cleanup)
snapshot-manager run
snapshot-manager run mypool/Documents

# Simulation mode (recommended for testing)
snapshot-manager --dry-run run
```

### Options

| Option            | Description                                         |
| ----------------- | --------------------------------------------------- |
| `--dry-run`       | Simulation mode, performs no changes                |
| `--verbose`       | Displays debug messages                             |
| `--force`         | Forces creation even if the snapshot already exists |
| `--config <file>` | Uses an alternative configuration file              |

## Examples

### Scenario: NAS powered off on Monday

```
Week of December 23–29, 2024
├── Monday 23    : NAS powered off ❌
├── Tuesday 24   : NAS powered off ❌
├── Wednesday 25 : NAS powered on ✓
│   └── 10:00 PM: snapshot-manager detects missing @weekly_2024-12-23
│                → Creates the snapshot with Monday’s date
└── Result: @weekly_2024-12-23 created on Wednesday
```

### Daily check

```bash
# See what will be done
snapshot-manager --dry-run run

# Execute if everything is OK
snapshot-manager run

# Verify the result
snapshot-manager status
```

### List snapshots with details

```bash
$ snapshot-manager list mypool/Documents

--- Documents (mypool/Documents) ---

  @weekly_2024-12-02   12K   Mon Dec  2 22:00 2024
  @weekly_2024-12-09   8K    Mon Dec  9 22:00 2024
  @weekly_2024-12-16   16K   Mon Dec 16 22:00 2024
  @weekly_2024-12-23   4K    Wed Dec 25 22:00 2024

  Total: 4 snapshot(s)
```

## Files

| File          | Location                                     | Description         |
| ------------- | -------------------------------------------- | ------------------- |
| Main script   | `/root/snapshot-manager/snapshot-manager.sh` | Snapshot manager    |
| Configuration | `/root/snapshot-manager/config.txt`          | Dataset definitions |
| Logs          | `/var/log/snapshot-manager.log`              | Operation log       |

## Troubleshooting

### The script cannot find my datasets

```bash
# Verify that the dataset exists
zfs list mypool/Documents

# Check the syntax in config.txt
grep "mypool/Documents" /root/snapshot-manager/config.txt
```

### Snapshots are not being created

```bash
# Check logs
tail -50 /var/log/snapshot-manager.log

# Test in verbose mode
snapshot-manager --verbose --dry-run run
```

### Verify the cron job

```bash
crontab -l | grep snapshot-manager
```

## Uninstallation

```bash
cd /tmp/snapshot-manager  # or the location of install.sh
./install.sh --uninstall
```

## License

MIT License – Free to use and modify.
