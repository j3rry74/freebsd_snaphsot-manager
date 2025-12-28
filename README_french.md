# Snapshot Manager

Gestionnaire intelligent de snapshots ZFS pour FreeNAS/FreeBSD avec support **cold storage**.

## Caractéristiques

- **Snapshots intelligents** : Crée les snapshots manqués si le NAS était éteint
- **Politiques flexibles** : journalier, hebdomadaire, mensuel, trimestriel
- **Rétention automatique** : Nettoyage configurable des anciens snapshots
- **Mode dry-run** : Simulation sans modification
- **Logs détaillés** : Suivi complet des opérations

## Installation

### Installation rapide

```bash
# Copier les fichiers sur le NAS
scp -r snapshot-manager/ root@nas:/tmp/

# Sur le NAS, lancer l'installation
ssh root@nas
cd /tmp/snapshot-manager
chmod +x install.sh
./install.sh
```

### Installation manuelle

```bash
# Créer le répertoire
mkdir -p /root/snapshot-manager

# Copier les fichiers
cp snapshot-manager.sh /root/snapshot-manager/
cp config.txt /root/snapshot-manager/

# Permissions
chmod 755 /root/snapshot-manager/snapshot-manager.sh
chmod 644 /root/snapshot-manager/config.txt

# Lien symbolique (optionnel)
ln -s /root/snapshot-manager/snapshot-manager.sh /usr/local/bin/snapshot-manager

# Tâche cron (exécution quotidienne à 22h)
echo "0 22 * * * /root/snapshot-manager/snapshot-manager.sh run >> /var/log/snapshot-manager.log 2>&1" | crontab -
```

## Configuration

Éditez `/root/snapshot-manager/config.txt` :

```ini
# Suppression automatique des snapshots expirés
AUTO_DELETE=no  # 'yes' pour activer

# Format: DATASET:<nom>:<politique>:<retention>:<unité>:<actif>
DATASET:mypool/Documents:weekly:30:days:yes
DATASET:mypool/Photos:monthly:12:months:yes
```

### Politiques disponibles

| Politique | Format du snapshot | Exemple |
|-----------|-------------------|---------|
| `daily` | `@daily_YYYY-MM-DD` | `@daily_2024-12-26` |
| `weekly` | `@weekly_YYYY-MM-DD` | `@weekly_2024-12-23` (date du lundi) |
| `monthly` | `@monthly_YYYY-MM` | `@monthly_2024-12` |
| `quarterly` | `@quarterly_YYYY-MM` | `@quarterly_2024-10` (mois: 01,04,07,10) |

### Unités de rétention

- `days` : jours
- `months` : mois
- `years` : années

## Utilisation

### Commandes principales

```bash
# Afficher l'aide
snapshot-manager help

# Voir l'état de tous les datasets
snapshot-manager status

# Lister les snapshots
snapshot-manager list
snapshot-manager list mypool/Documents

# Exécuter (création + nettoyage)
snapshot-manager run
snapshot-manager run mypool/Documents

# Mode simulation (recommandé pour tester)
snapshot-manager --dry-run run
```

### Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Mode simulation, n'effectue aucune modification |
| `--verbose` | Affiche les messages de debug |
| `--force` | Force la création même si le snapshot existe |
| `--config <fichier>` | Utilise un fichier de configuration alternatif |

## Exemples

### Scénario : NAS éteint le lundi

```
Semaine du 23-29 décembre 2024
├── Lundi 23    : NAS éteint ❌
├── Mardi 24    : NAS éteint ❌
├── Mercredi 25 : NAS allumé ✓
│   └── 22h : snapshot-manager détecte l'absence de @weekly_2024-12-23
│             → Crée le snapshot avec la date du lundi
└── Résultat : @weekly_2024-12-23 créé le mercredi
```

### Vérification quotidienne

```bash
# Voir ce qui va être fait
snapshot-manager --dry-run run

# Exécuter si tout est OK
snapshot-manager run

# Vérifier le résultat
snapshot-manager status
```

### Lister les snapshots avec détails

```bash
$ snapshot-manager list mypool/Documents

--- Documents (mypool/Documents) ---

  @weekly_2024-12-02   12K   Mon Dec  2 22:00 2024
  @weekly_2024-12-09   8K    Mon Dec  9 22:00 2024
  @weekly_2024-12-16   16K   Mon Dec 16 22:00 2024
  @weekly_2024-12-23   4K    Wed Dec 25 22:00 2024

  Total: 4 snapshot(s)
```

## Fichiers

| Fichier | Emplacement | Description |
|---------|-------------|-------------|
| Script principal | `/root/snapshot-manager/snapshot-manager.sh` | Gestionnaire de snapshots |
| Configuration | `/root/snapshot-manager/config.txt` | Définition des datasets |
| Logs | `/var/log/snapshot-manager.log` | Journal des opérations |

## Dépannage

### Le script ne trouve pas mes datasets

```bash
# Vérifier que le dataset existe
zfs list mypool/Documents

# Vérifier la syntaxe dans config.txt
grep "mypool/Documents" /root/snapshot-manager/config.txt
```

### Les snapshots ne sont pas créés

```bash
# Vérifier les logs
tail -50 /var/log/snapshot-manager.log

# Tester en mode verbeux
snapshot-manager --verbose --dry-run run
```

### Vérifier la tâche cron

```bash
crontab -l | grep snapshot-manager
```

## Désinstallation

```bash
cd /tmp/snapshot-manager  # ou l'emplacement de install.sh
./install.sh --uninstall
```

## Licence

MIT License - Libre d'utilisation et de modification.
