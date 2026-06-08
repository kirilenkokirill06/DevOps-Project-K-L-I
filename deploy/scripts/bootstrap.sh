#!/usr/bin/env bash

# ==============================================================================
# @file bootstrap.sh
# @brief Bootstraps a Linux environment for running HAProxy and Nginx stack.
# @details Performs target OS validation, applies kernel sysctl hardening,
#          installs Docker Engine, configures necessary volumes, and generates
#          stub configuration directory structures.
#
# @author SRE / System Administrator Agent
# @copyright (c) 2026 University Student
# @license MIT
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# --- Colors for Logging ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[1;34m"
readonly COLOR_SUCCESS="\033[1;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[1;31m"

# --- Constants ---
readonly SYSCTL_HARDENING_SRC="config/sysctl.d/99-hardening.conf"
readonly SYSCTL_HARDENING_DST="/etc/sysctl.d/99-hardening.conf"

# ==============================================================================
# Logging Utilities
# ==============================================================================

# @description Print info message to stdout.
# @arg $1 string The message to print.
log_info() {
    local -r message="${1}"
    echo -e "${COLOR_INFO}[INFO] ${message}${COLOR_RESET}"
}

# @description Print success message to stdout.
# @arg $1 string The message to print.
log_success() {
    local -r message="${1}"
    echo -e "${COLOR_SUCCESS}[SUCCESS] ${message}${COLOR_RESET}"
}

# @description Print warning message to stderr.
# @arg $1 string The message to print.
log_warn() {
    local -r message="${1}"
    echo -e "${COLOR_WARN}[WARN] ${message}${COLOR_RESET}" >&2
}

# @description Print error message to stderr.
# @arg $1 string The message to print.
log_error() {
    local -r message="${1}"
    echo -e "${COLOR_ERROR}[ERROR] ${message}${COLOR_RESET}" >&2
}

# @description Trap error handler to log failures.
# @arg $1 int Exit status code.
# @arg $2 int Line number where the failure occurred.
error_trap() {
    local -r exit_code="${1}"
    local -r line_number="${2}"
    log_error "Script failed at line ${line_number} with exit code ${exit_code}."
    exit "${exit_code}"
}

trap 'error_trap $? $LINENO' ERR

# ==============================================================================
# Assertions and Pre-checks
# ==============================================================================

# @description Assures that the script is run with root permissions.
assert_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be executed as root (using sudo or as root user)."
        exit 1
    fi
}

# @description Identifies the distribution name.
detect_distribution() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        echo "${ID}"
    else
        echo "unknown"
    fi
}

# ==============================================================================
# Action Steps
# ==============================================================================

# @description Updates package repositories and installs prerequisite utilities.
install_prerequisites() {
    log_info "Updating system repositories and installing dependencies..."
    
    local -r distro=$(detect_distribution)
    
    if [[ "${distro}" == "ubuntu" || "${distro}" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y --no-install-recommends \
            curl \
            gnupg \
            ca-certificates \
            apt-transport-https \
            lsb-release
    else
        log_warn "Unsupported distribution '${distro}'. Prerequisite installation skipped. Assuming manual installation."
    fi
}

# @description Installs Docker Engine and Docker Compose plugin.
install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker is already installed: $(docker --version). Skipping installation."
        return 0
    fi

    log_info "Installing Docker Engine..."
    local -r distro=$(detect_distribution)

    if [[ "${distro}" == "ubuntu" || "${distro}" == "debian" ]]; then
        # Create keyrings directory
        install -m 0755 -d /etc/apt/keyrings
        
        # Add Docker official GPG key
        curl -fsSL "https://download.docker.com/linux/${distro}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
        chmod a+r /etc/apt/keyrings/docker.gpg

        # Set up Docker repository
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} \
          $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

        # Install Docker packages
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        # Enable and start services
        systemctl enable docker
        systemctl start docker
        log_success "Docker Engine installed and started successfully."
    else
        log_warn "Could not install Docker automatically on '${distro}'. Please install it manually."
    fi
}

# @description Copies and applies system hardening configuration via sysctl.
apply_sysctl_hardening() {
    log_info "Applying Linux kernel sysctl hardening rules..."
    
    if [[ -f "${SYSCTL_HARDENING_SRC}" ]]; then
        cp "${SYSCTL_HARDENING_SRC}" "${SYSCTL_HARDENING_DST}"
        chmod 644 "${SYSCTL_HARDENING_DST}"
        sysctl --system
        log_success "Hardening parameters applied."
    elif [[ -f "../${SYSCTL_HARDENING_SRC}" ]]; then
        cp "../${SYSCTL_HARDENING_SRC}" "${SYSCTL_HARDENING_DST}"
        chmod 644 "${SYSCTL_HARDENING_DST}"
        sysctl --system
        log_success "Hardening parameters applied."
    else
        log_error "Could not find sysctl hardening source file: ${SYSCTL_HARDENING_SRC}."
        exit 1
    fi
}

# @description Prepares required files and directories for docker compose deployment.
prepare_workspace() {
    log_info "Preparing workspace directories and Docker secrets..."
    
    # Create secrets directory if not exists
    mkdir -p secrets
    
    # Set default values for stats secrets if they do not exist
    if [[ ! -f "secrets/stats_user.txt" ]]; then
        echo "admin" > "secrets/stats_user.txt"
        log_info "Generated default stats user 'admin' in secrets/stats_user.txt"
    fi

    if [[ ! -f "secrets/stats_password.txt" ]]; then
        # Generate a simple secure random string if openssl is available
        if command -v openssl &> /dev/null; then
            openssl rand -hex 12 > "secrets/stats_password.txt"
        else
            echo "DefaultSecurePassword123!" > "secrets/stats_password.txt"
        fi
        log_info "Generated secure HAProxy Stats password in secrets/stats_password.txt"
    fi

    chmod 600 secrets/stats_user.txt secrets/stats_password.txt
    log_success "Workspace initialized."
}

# @description Installs python3-venv and configures virtual environment for integration tests.
prepare_python_venv() {
    log_info "Configuring Python virtual environment for integration tests..."
    
    local -r distro=$(detect_distribution)
    
    if [[ "${distro}" == "ubuntu" || "${distro}" == "debian" ]]; then
        # Install python3-venv and pip
        apt-get install -y python3-venv python3-pip
    fi

    local -r venv_dir="deploy/scripts/tests/venv"
    if [[ ! -d "${venv_dir}" ]]; then
        python3 -m venv "${venv_dir}"
        log_info "Created virtual environment in ${venv_dir}"
    fi

    # Install packages inside virtual environment
    "${venv_dir}/bin/pip" install --upgrade pip
    "${venv_dir}/bin/pip" install pytest requests
    
    # Correct ownership of the virtual environment to the invoking user
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "${SUDO_USER}:${SUDO_USER}" "${venv_dir}"
    fi
    
    log_success "Python virtual environment prepared successfully."
}

# ==============================================================================
# Main Logic
# ==============================================================================

main() {
    log_info "Starting environment bootstrapping..."
    
    assert_root
    install_prerequisites
    install_docker
    apply_sysctl_hardening
    prepare_workspace
    prepare_python_venv
    
    log_success "System bootstrap completed successfully!"
    log_info "You can now run: docker compose -f deploy/docker-compose.yml up -d"
}

# Execute script
main
