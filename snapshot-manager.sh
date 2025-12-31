#!/bin/sh
# shellcheck disable=SC3043  # 'local' is supported in FreeBSD sh
#
# snapshot-manager.sh - Gestionnaire intelligent de snapshots ZFS
# Pour FreeNAS/FreeBSD avec support cold storage (NAS pas toujours allume)
#
# Usage: snapshot-manager.sh [command] [options]
#
# Commands:
#   run [dataset]     - Execute la creation/nettoyage des snapshots
#   status            - Affiche l'etat de tous les datasets
#   list [dataset]    - Liste les snapshots existants
#   help              - Affiche cette aide
#
# Options:
#   --dry-run         - Mode simulation (n'execute rien)
#   --verbose         - Mode verbeux
#   --force           - Force la creation meme si le snapshot existe
#

set -u

# ============================================================================
# CONFIGURATION PAR DEFAUT
# ============================================================================

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="${SCRIPT_DIR}/config.txt"
LOG_FILE="/var/log/snapshot-manager.log"
LOG_MAX_SIZE=10485760  # 10 MB
DRY_RUN=0
VERBOSE=0
FORCE=0

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

# Affiche un message avec horodatage
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # Ecrire dans le log
    if [ -n "$LOG_FILE" ] && [ -w "$(dirname "$LOG_FILE")" ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi

    # Afficher a l'ecran selon le niveau
    case "$level" in
        ERROR)
            echo "ERREUR: $message" >&2
            ;;
        WARN)
            echo "ATTENTION: $message" >&2
            ;;
        INFO)
            echo "$message"
            ;;
        DEBUG)
            if [ "$VERBOSE" -eq 1 ]; then
                echo "[DEBUG] $message"
            fi
            ;;
    esac
}

# Rotation des logs si necessaire
rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt "$LOG_MAX_SIZE" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            log INFO "Rotation du fichier de log effectuee"
        fi
    fi
}

# Verifie si une commande existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================================
# FONCTIONS DE DATE
# ============================================================================

# Retourne la date du jour au format YYYY-MM-DD
get_today() {
    date "+%Y-%m-%d"
}

# Retourne le mois courant au format YYYY-MM
get_current_month() {
    date "+%Y-%m"
}

# Retourne l'annee courante
get_current_year() {
    date "+%Y"
}

# Retourne le numero du mois courant (01-12)
get_month_number() {
    date "+%m"
}

# Retourne le trimestre courant au format YYYY-MM (mois de debut: 01, 04, 07, 10)
get_current_quarter() {
    local year month quarter_month
    year=$(date "+%Y")
    month=$(date "+%m" | sed 's/^0//')

    if [ "$month" -le 3 ]; then
        quarter_month="01"
    elif [ "$month" -le 6 ]; then
        quarter_month="04"
    elif [ "$month" -le 9 ]; then
        quarter_month="07"
    else
        quarter_month="10"
    fi

    echo "${year}-${quarter_month}"
}

# Retourne la date du lundi de la semaine courante au format YYYY-MM-DD
get_monday_of_week() {
    local day_of_week days_since_monday
    # 1=lundi, 7=dimanche
    day_of_week=$(date "+%u")
    days_since_monday=$((day_of_week - 1))

    if [ "$days_since_monday" -eq 0 ]; then
        date "+%Y-%m-%d"
    else
        # FreeBSD date syntax
        date -v-${days_since_monday}d "+%Y-%m-%d" 2>/dev/null || \
        # Linux date syntax fallback
        date -d "-${days_since_monday} days" "+%Y-%m-%d" 2>/dev/null
    fi
}

# Calcule une date dans le passe (FreeBSD compatible)
# Usage: date_minus_days <nombre_jours>
date_minus_days() {
    local days="$1"
    date -v-"${days}"d "+%Y-%m-%d" 2>/dev/null || \
    date -d "-${days} days" "+%Y-%m-%d" 2>/dev/null
}

# Calcule une date dans le passe en mois
# Usage: date_minus_months <nombre_mois>
date_minus_months() {
    local months="$1"
    date -v-"${months}"m "+%Y-%m" 2>/dev/null || \
    date -d "-${months} months" "+%Y-%m" 2>/dev/null
}

# ============================================================================
# FONCTIONS DE CONFIGURATION
# ============================================================================

# Charge et valide la configuration
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log ERROR "Fichier de configuration non trouve: $CONFIG_FILE"
        return 1
    fi

    # Charger les variables globales du config
    eval "$(grep -E "^(LOG_FILE|LOG_MAX_SIZE|AUTO_DELETE)=" "$CONFIG_FILE" | grep -v "^#")"

    log DEBUG "Configuration chargee depuis $CONFIG_FILE"
    return 0
}

# Retourne la liste des datasets actifs
get_datasets() {
    grep -E "^DATASET:" "$CONFIG_FILE" | while read -r line; do
        local dataset enabled
        dataset=$(echo "$line" | cut -d: -f2 | tr -d ' ')
        enabled=$(echo "$line" | cut -d: -f6 | tr -d ' ')
        if [ "$enabled" = "yes" ]; then
            echo "$dataset"
        fi
    done
}

# Retourne la politique d'un dataset
# Usage: get_policy <dataset>
get_policy() {
    local dataset="$1"
    grep -E "^DATASET:${dataset}:" "$CONFIG_FILE" | cut -d: -f3 | tr -d ' '
}

# Retourne la retention d'un dataset (en jours ou mois selon la politique)
# Usage: get_retention <dataset>
get_retention() {
    local dataset="$1"
    grep -E "^DATASET:${dataset}:" "$CONFIG_FILE" | cut -d: -f4 | tr -d ' '
}

# Retourne l'unite de retention
# Usage: get_retention_unit <dataset>
get_retention_unit() {
    local dataset="$1"
    grep -E "^DATASET:${dataset}:" "$CONFIG_FILE" | cut -d: -f5 | tr -d ' '
}

# Verifie si un dataset existe dans ZFS
dataset_exists() {
    local dataset="$1"
    zfs list -H -o name "$dataset" >/dev/null 2>&1
}

# ============================================================================
# FONCTIONS DE SNAPSHOTS
# ============================================================================

# Genere le nom du snapshot selon la politique
# Usage: generate_snapshot_name <policy>
generate_snapshot_name() {
    local policy="$1"

    case "$policy" in
        daily)
            echo "@daily_$(get_today)"
            ;;
        weekly)
            echo "@weekly_$(get_monday_of_week)"
            ;;
        monthly)
            echo "@monthly_$(get_current_month)"
            ;;
        quarterly)
            echo "@quarterly_$(get_current_quarter)"
            ;;
        *)
            log ERROR "Politique inconnue: $policy"
            return 1
            ;;
    esac
}

# Verifie si un snapshot existe
# Usage: snapshot_exists <dataset> <snapshot_name>
snapshot_exists() {
    local dataset="$1"
    local snapshot_name="$2"
    zfs list -H -t snapshot -o name "${dataset}${snapshot_name}" >/dev/null 2>&1
}

# Cree un snapshot
# Usage: create_snapshot <dataset> <snapshot_name>
create_snapshot() {
    local dataset="$1"
    local snapshot_name="$2"
    local full_name="${dataset}${snapshot_name}"

    if [ "$DRY_RUN" -eq 1 ]; then
        log INFO "[DRY-RUN] Aurait cree: $full_name"
        return 0
    fi

    if zfs snapshot "$full_name"; then
        log INFO "Snapshot cree: $full_name"
        return 0
    else
        log ERROR "Echec de creation du snapshot: $full_name"
        return 1
    fi
}

# Supprime un snapshot
# Usage: delete_snapshot <dataset> <snapshot_name>
delete_snapshot() {
    local dataset="$1"
    local snapshot_name="$2"
    local full_name="${dataset}${snapshot_name}"

    if [ "$DRY_RUN" -eq 1 ]; then
        log INFO "[DRY-RUN] Aurait supprime: $full_name"
        return 0
    fi

    if zfs destroy "$full_name"; then
        log INFO "Snapshot supprime: $full_name"
        return 0
    else
        log ERROR "Echec de suppression du snapshot: $full_name"
        return 1
    fi
}

# Liste les snapshots d'un dataset avec un prefixe donne
# Usage: list_snapshots <dataset> <prefix>
list_snapshots() {
    local dataset="$1"
    local prefix="$2"
    zfs list -H -t snapshot -o name -s creation "${dataset}" 2>/dev/null | \
        grep "@${prefix}_" | \
        sed "s|${dataset}||"
}

# Retourne la date d'un snapshot selon son nom
# Usage: get_snapshot_date <snapshot_name>
get_snapshot_date() {
    local snapshot_name="$1"
    echo "$snapshot_name" | sed 's/@[a-z]*_//'
}

# Compare deux dates (format YYYY-MM-DD ou YYYY-MM)
# Retourne 0 si date1 < date2, 1 sinon
# Usage: date_is_before <date1> <date2>
date_is_before() {
    local date1="$1"
    local date2="$2"
    # Convertir en nombre comparable (retirer les tirets)
    local num1 num2
    num1=$(echo "$date1" | tr -d '-')
    num2=$(echo "$date2" | tr -d '-')
    [ "$num1" -lt "$num2" ]
}

# ============================================================================
# GESTION DE LA RETENTION
# ============================================================================

# Calcule les snapshots a supprimer selon la politique de retention
# Usage: get_expired_snapshots <dataset>
get_expired_snapshots() {
    local dataset="$1"
    local policy retention unit prefix

    policy=$(get_policy "$dataset")
    retention=$(get_retention "$dataset")
    unit=$(get_retention_unit "$dataset")

    case "$policy" in
        daily)
            prefix="daily"
            ;;
        weekly)
            prefix="weekly"
            ;;
        monthly)
            prefix="monthly"
            ;;
        quarterly)
            prefix="quarterly"
            ;;
    esac

    # Calculer la date limite
    local cutoff_date
    case "$unit" in
        days)
            cutoff_date=$(date_minus_days "$retention")
            ;;
        months)
            cutoff_date=$(date_minus_months "$retention")
            ;;
        years)
            local months=$((retention * 12))
            cutoff_date=$(date_minus_months "$months")
            ;;
    esac

    log DEBUG "Dataset: $dataset, Politique: $policy, Retention: $retention $unit, Date limite: $cutoff_date"

    # Lister les snapshots expires
    list_snapshots "$dataset" "$prefix" | while read -r snap; do
        local snap_date
        snap_date=$(get_snapshot_date "$snap")
        if date_is_before "$snap_date" "$cutoff_date"; then
            echo "$snap"
        fi
    done
}

# Nettoie les snapshots expires d'un dataset
# Usage: cleanup_dataset <dataset>
cleanup_dataset() {
    local dataset="$1"
    local auto_delete

    auto_delete=$(grep "^AUTO_DELETE=" "$CONFIG_FILE" | cut -d= -f2 | tr -d ' ')

    local expired_count=0

    get_expired_snapshots "$dataset" | while read -r snap; do
        if [ -n "$snap" ]; then
            expired_count=$((expired_count + 1))
            if [ "$auto_delete" = "yes" ]; then
                delete_snapshot "$dataset" "$snap"
            else
                log INFO "Snapshot expire (suppression manuelle requise): ${dataset}${snap}"
            fi
        fi
    done
}

# ============================================================================
# COMMANDES PRINCIPALES
# ============================================================================

# Commande: run
cmd_run() {
    local target_dataset="$1"

    log INFO "=== Debut de l'execution $(date '+%Y-%m-%d %H:%M:%S') ==="

    if [ -n "$target_dataset" ]; then
        # Execution pour un dataset specifique
        if ! dataset_exists "$target_dataset"; then
            log ERROR "Dataset non trouve: $target_dataset"
            return 1
        fi

        process_dataset "$target_dataset"
    else
        # Execution pour tous les datasets actifs
        get_datasets | while read -r dataset; do
            if [ -n "$dataset" ]; then
                process_dataset "$dataset"
            fi
        done
    fi

    log INFO "=== Fin de l'execution ==="
}

# Traite un dataset (creation + nettoyage)
process_dataset() {
    local dataset="$1"
    local policy snapshot_name

    if ! dataset_exists "$dataset"; then
        log WARN "Dataset non trouve dans ZFS: $dataset"
        return 1
    fi

    policy=$(get_policy "$dataset")
    if [ -z "$policy" ]; then
        log WARN "Pas de politique definie pour: $dataset"
        return 1
    fi

    snapshot_name=$(generate_snapshot_name "$policy")
    if [ -z "$snapshot_name" ]; then
        return 1
    fi

    log DEBUG "Traitement de $dataset (politique: $policy)"

    # Verifier si le snapshot existe deja
    if snapshot_exists "$dataset" "$snapshot_name"; then
        if [ "$FORCE" -eq 1 ]; then
            log INFO "Snapshot existe deja mais force: ${dataset}${snapshot_name}"
        else
            log DEBUG "Snapshot existe deja: ${dataset}${snapshot_name}"
        fi
    else
        create_snapshot "$dataset" "$snapshot_name"
    fi

    # Nettoyage des snapshots expires
    cleanup_dataset "$dataset"
}

# Commande: status
cmd_status() {
    echo ""
    echo "========================================================================"
    echo "                    ETAT DES SNAPSHOTS ZFS"
    echo "========================================================================"
    echo ""

    printf "%-25s %-12s %-12s %-20s\n" "DATASET" "POLITIQUE" "RETENTION" "DERNIER SNAPSHOT"
    printf "%-25s %-12s %-12s %-20s\n" "-------------------------" "------------" "------------" "--------------------"

    get_datasets | while read -r dataset; do
        if [ -n "$dataset" ]; then
            local policy retention unit last_snap prefix
            policy=$(get_policy "$dataset")
            retention=$(get_retention "$dataset")
            unit=$(get_retention_unit "$dataset")

            case "$policy" in
                daily) prefix="daily" ;;
                weekly) prefix="weekly" ;;
                monthly) prefix="monthly" ;;
                quarterly) prefix="quarterly" ;;
            esac

            # Trouver le dernier snapshot
            last_snap=$(list_snapshots "$dataset" "$prefix" | tail -1)
            if [ -z "$last_snap" ]; then
                last_snap="(aucun)"
            fi

            # Nom court du dataset
            local short_name
            short_name=$(echo "$dataset" | sed 's|.*/||')

            printf "%-25s %-12s %-12s %-20s\n" "$short_name" "$policy" "${retention} ${unit}" "$last_snap"
        fi
    done

    echo ""
    echo "========================================================================"

    # Afficher les snapshots expires
    echo ""
    echo "SNAPSHOTS EXPIRES (a supprimer):"
    echo "--------------------------------"

    local expired_list
    expired_list=$(
        get_datasets | while read -r dataset; do
            if [ -n "$dataset" ]; then
                get_expired_snapshots "$dataset" | while read -r snap; do
                    if [ -n "$snap" ]; then
                        echo "  ${dataset}${snap}"
                    fi
                done
            fi
        done
    )

    if [ -n "$expired_list" ]; then
        echo "$expired_list"
    else
        echo "  (aucun)"
    fi

    echo ""
}

# Commande: list
cmd_list() {
    local target_dataset="$1"

    echo ""
    echo "========================================================================"
    echo "                    LISTE DES SNAPSHOTS"
    echo "========================================================================"

    list_dataset_snapshots() {
        local dataset="$1"
        local short_name
        short_name=$(echo "$dataset" | sed 's|.*/||')

        echo ""
        echo "--- $short_name ($dataset) ---"
        echo ""

        # Recuperer tous les snapshots avec leurs infos
        zfs list -H -t snapshot -o name,used,creation -s creation "$dataset" 2>/dev/null | \
        grep -E "@(daily|weekly|monthly|quarterly)_" | \
        while read -r name used creation; do
            local snap_name
            snap_name=$(echo "$name" | sed "s|${dataset}||")
            printf "  %-30s  %10s  %s\n" "$snap_name" "$used" "$creation"
        done

        local count
        count=$(zfs list -H -t snapshot -o name "$dataset" 2>/dev/null | grep -c -E "@(daily|weekly|monthly|quarterly)_" || echo 0)
        echo ""
        echo "  Total: $count snapshot(s)"
    }

    if [ -n "$target_dataset" ]; then
        if dataset_exists "$target_dataset"; then
            list_dataset_snapshots "$target_dataset"
        else
            log ERROR "Dataset non trouve: $target_dataset"
            return 1
        fi
    else
        get_datasets | while read -r dataset; do
            if [ -n "$dataset" ]; then
                list_dataset_snapshots "$dataset"
            fi
        done
    fi

    echo ""
    echo "========================================================================"
    echo ""
}

# Commande: help
cmd_help() {
    cat << 'EOF'

SNAPSHOT-MANAGER - Gestionnaire intelligent de snapshots ZFS
=============================================================

UTILISATION:
    snapshot-manager.sh [commande] [options] [arguments]

COMMANDES:
    run [dataset]     Execute la creation et le nettoyage des snapshots
                      Sans argument: traite tous les datasets actifs
                      Avec argument: traite uniquement le dataset specifie

    status            Affiche un tableau recapitulatif:
                      - Etat de chaque dataset
                      - Dernier snapshot
                      - Snapshots expires

    list [dataset]    Liste tous les snapshots geres
                      Sans argument: tous les datasets
                      Avec argument: uniquement le dataset specifie

    help              Affiche cette aide

OPTIONS:
    --dry-run         Mode simulation - affiche ce qui serait fait
                      sans effectuer aucune modification

    --verbose         Mode verbeux - affiche les messages de debug

    --force           Force la creation meme si le snapshot existe

EXEMPLES:
    # Lancer en mode simulation
    snapshot-manager.sh --dry-run run

    # Voir l'etat de tous les datasets
    snapshot-manager.sh status

    # Lister les snapshots d'un dataset specifique
    snapshot-manager.sh list mypool/Documents

    # Forcer la creation pour un dataset
    snapshot-manager.sh --force run mypool/Photos

CONFIGURATION:
    Fichier: /root/snapshot-manager/config.txt

LOGS:
    Fichier: /var/log/snapshot-manager.log

EOF
}

# ============================================================================
# POINT D'ENTREE
# ============================================================================

main() {
    local command=""
    local argument=""

    # Parser les arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                log INFO "Mode simulation active"
                ;;
            --verbose)
                VERBOSE=1
                ;;
            --force)
                FORCE=1
                ;;
            --config)
                shift
                CONFIG_FILE="$1"
                ;;
            run|status|list|help)
                command="$1"
                ;;
            *)
                if [ -z "$argument" ]; then
                    argument="$1"
                fi
                ;;
        esac
        shift
    done

    # Commande par defaut
    if [ -z "$command" ]; then
        command="help"
    fi

    # Rotation des logs
    rotate_log

    # Charger la configuration (sauf pour help)
    if [ "$command" != "help" ]; then
        if ! load_config; then
            exit 1
        fi
    fi

    # Executer la commande
    case "$command" in
        run)
            cmd_run "$argument"
            ;;
        status)
            cmd_status
            ;;
        list)
            cmd_list "$argument"
            ;;
        help)
            cmd_help
            ;;
        *)
            log ERROR "Commande inconnue: $command"
            cmd_help
            exit 1
            ;;
    esac
}

# Execution
main "$@"
