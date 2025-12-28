#!/bin/sh
#
# install.sh - Script d'installation de snapshot-manager
# Pour FreeNAS/FreeBSD
#

set -e

# Configuration
INSTALL_DIR="/root/snapshot-manager"
LOG_FILE="/var/log/snapshot-manager.log"
CRON_TIME="0 22 * * *"  # Tous les jours a 22h00
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# Couleurs (si terminal supporte)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Fonctions d'affichage
info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

error() {
    printf "${RED}[ERREUR]${NC} %s\n" "$1" >&2
}

success() {
    printf "${GREEN}[OK]${NC} %s\n" "$1"
}

# Verification des prerequis
check_prerequisites() {
    info "Verification des prerequis..."

    # Verifier qu'on est root
    if [ "$(id -u)" -ne 0 ]; then
        error "Ce script doit etre execute en tant que root"
        exit 1
    fi

    # Verifier ZFS
    if ! command -v zfs >/dev/null 2>&1; then
        error "ZFS n'est pas installe ou n'est pas dans le PATH"
        exit 1
    fi

    # Verifier que les fichiers sources existent
    if [ ! -f "${SCRIPT_DIR}/snapshot-manager.sh" ]; then
        error "snapshot-manager.sh non trouve dans ${SCRIPT_DIR}"
        exit 1
    fi

    if [ ! -f "${SCRIPT_DIR}/config.txt" ]; then
        error "config.txt non trouve dans ${SCRIPT_DIR}"
        exit 1
    fi

    success "Prerequis OK"
}

# Creation des repertoires
create_directories() {
    info "Creation des repertoires..."

    if [ -d "$INSTALL_DIR" ]; then
        warn "Le repertoire $INSTALL_DIR existe deja"
    else
        mkdir -p "$INSTALL_DIR"
        success "Repertoire cree: $INSTALL_DIR"
    fi

    # Creer le repertoire de log si necessaire
    LOG_DIR=$(dirname "$LOG_FILE")
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        success "Repertoire de log cree: $LOG_DIR"
    fi
}

# Copie des fichiers
copy_files() {
    info "Copie des fichiers..."

    # Copier le script principal
    cp "${SCRIPT_DIR}/snapshot-manager.sh" "${INSTALL_DIR}/"
    chmod 755 "${INSTALL_DIR}/snapshot-manager.sh"
    success "snapshot-manager.sh installe"

    # Copier la configuration (sans ecraser si existante)
    if [ -f "${INSTALL_DIR}/config.txt" ]; then
        warn "config.txt existe deja, sauvegarde en config.txt.new"
        cp "${SCRIPT_DIR}/config.txt" "${INSTALL_DIR}/config.txt.new"
    else
        cp "${SCRIPT_DIR}/config.txt" "${INSTALL_DIR}/"
        success "config.txt installe"
    fi

    # Permissions
    chmod 644 "${INSTALL_DIR}/config.txt"*
    chown -R root:wheel "$INSTALL_DIR"
}

# Creation du lien symbolique
create_symlink() {
    info "Creation du lien symbolique..."

    local link_path="/usr/local/bin/snapshot-manager"

    if [ -L "$link_path" ]; then
        rm "$link_path"
    fi

    ln -s "${INSTALL_DIR}/snapshot-manager.sh" "$link_path"
    success "Lien cree: $link_path"
}

# Configuration du cron
setup_cron() {
    info "Configuration de la tache cron..."

    local cron_line="${CRON_TIME} ${INSTALL_DIR}/snapshot-manager.sh run >> ${LOG_FILE} 2>&1"
    local cron_comment="# Snapshot Manager - Gestion automatique des snapshots ZFS"

    # Verifier si la tache existe deja
    if crontab -l 2>/dev/null | grep -q "snapshot-manager.sh"; then
        warn "Une tache cron existe deja pour snapshot-manager"
        echo ""
        echo "Tache actuelle:"
        crontab -l 2>/dev/null | grep "snapshot-manager"
        echo ""
        printf "Voulez-vous la remplacer? [o/N] "
        read -r response
        if [ "$response" != "o" ] && [ "$response" != "O" ]; then
            info "Tache cron conservee"
            return
        fi
        # Supprimer l'ancienne entree
        crontab -l 2>/dev/null | grep -v "snapshot-manager" | crontab -
    fi

    # Ajouter la nouvelle tache
    (crontab -l 2>/dev/null; echo "$cron_comment"; echo "$cron_line") | crontab -

    success "Tache cron configuree: tous les jours a 22h00"
}

# Initialisation du fichier de log
init_log() {
    info "Initialisation du fichier de log..."

    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
        success "Fichier de log cree: $LOG_FILE"
    else
        info "Fichier de log existant: $LOG_FILE"
    fi
}

# Verification de la configuration
verify_config() {
    info "Verification de la configuration..."

    echo ""
    echo "Datasets configures:"
    echo "--------------------"

    grep "^DATASET:" "${INSTALL_DIR}/config.txt" | while read -r line; do
        local dataset enabled
        dataset=$(echo "$line" | cut -d: -f2)
        enabled=$(echo "$line" | cut -d: -f6)

        if [ "$enabled" = "yes" ]; then
            if zfs list -H -o name "$dataset" >/dev/null 2>&1; then
                printf "  ${GREEN}[OK]${NC} %s\n" "$dataset"
            else
                printf "  ${YELLOW}[!]${NC} %s (dataset non trouve)\n" "$dataset"
            fi
        else
            printf "  ${YELLOW}[-]${NC} %s (desactive)\n" "$dataset"
        fi
    done

    echo ""
}

# Test en mode dry-run
run_test() {
    info "Test en mode simulation..."
    echo ""

    "${INSTALL_DIR}/snapshot-manager.sh" --dry-run --verbose run

    echo ""
    success "Test termine"
}

# Resume de l'installation
show_summary() {
    echo ""
    echo "========================================================================"
    echo "                    INSTALLATION TERMINEE"
    echo "========================================================================"
    echo ""
    echo "Fichiers installes:"
    echo "  - Script:  ${INSTALL_DIR}/snapshot-manager.sh"
    echo "  - Config:  ${INSTALL_DIR}/config.txt"
    echo "  - Log:     ${LOG_FILE}"
    echo "  - Lien:    /usr/local/bin/snapshot-manager"
    echo ""
    echo "Tache cron: tous les jours a 22h00"
    echo ""
    echo "Commandes disponibles:"
    echo "  snapshot-manager run          # Executer maintenant"
    echo "  snapshot-manager status       # Voir l'etat"
    echo "  snapshot-manager list         # Lister les snapshots"
    echo "  snapshot-manager --dry-run run  # Simulation"
    echo ""
    echo "IMPORTANT: Editez ${INSTALL_DIR}/config.txt"
    echo "           pour ajuster les datasets selon votre configuration."
    echo ""
    echo "========================================================================"
    echo ""
}

# Desinstallation
uninstall() {
    info "Desinstallation de snapshot-manager..."

    # Supprimer la tache cron
    if crontab -l 2>/dev/null | grep -q "snapshot-manager"; then
        crontab -l 2>/dev/null | grep -v "snapshot-manager" | crontab -
        success "Tache cron supprimee"
    fi

    # Supprimer le lien symbolique
    if [ -L "/usr/local/bin/snapshot-manager" ]; then
        rm "/usr/local/bin/snapshot-manager"
        success "Lien symbolique supprime"
    fi

    # Demander confirmation pour les fichiers
    echo ""
    printf "Supprimer les fichiers dans ${INSTALL_DIR}? [o/N] "
    read -r response
    if [ "$response" = "o" ] || [ "$response" = "O" ]; then
        rm -rf "$INSTALL_DIR"
        success "Fichiers supprimes"
    else
        info "Fichiers conserves dans $INSTALL_DIR"
    fi

    # Log
    printf "Supprimer le fichier de log ${LOG_FILE}? [o/N] "
    read -r response
    if [ "$response" = "o" ] || [ "$response" = "O" ]; then
        rm -f "$LOG_FILE" "${LOG_FILE}.old"
        success "Fichier de log supprime"
    fi

    echo ""
    success "Desinstallation terminee"
}

# Fonction principale
main() {
    echo ""
    echo "========================================================================"
    echo "           SNAPSHOT-MANAGER - Installation"
    echo "========================================================================"
    echo ""

    case "${1:-}" in
        --uninstall)
            uninstall
            exit 0
            ;;
        --help)
            echo "Usage: $0 [--uninstall] [--help]"
            echo ""
            echo "Options:"
            echo "  --uninstall    Desinstalle snapshot-manager"
            echo "  --help         Affiche cette aide"
            exit 0
            ;;
    esac

    # Installation
    check_prerequisites
    create_directories
    copy_files
    create_symlink
    setup_cron
    init_log
    verify_config

    # Demander si on veut faire un test
    echo ""
    printf "Voulez-vous executer un test en mode simulation? [O/n] "
    read -r response
    if [ "$response" != "n" ] && [ "$response" != "N" ]; then
        run_test
    fi

    show_summary
}

# Execution
main "$@"
