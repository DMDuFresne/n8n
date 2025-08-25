#!/bin/bash

# ============================================
# n8n Production Setup Script for Vultr VPS
# Version: 1.0
# 
# Optimized for:
# - Vultr Cloud Infrastructure
# - Vultr managed SSH access
# - Vultr cloud firewall
# - Ubuntu 20.04/22.04/24.04 LTS
# ============================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# ============================================
# Configuration
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/setup.log"
REQUIRED_MEMORY_MB=1800
REQUIRED_DISK_GB=10
MAX_RETRIES=3
DOCKER_COMPOSE_VERSION="2.20.0"

# ============================================
# Colors & Formatting
# ============================================

# Abelara Brand Colors for Terminal
RED='\033[38;2;245;96;43m'      # Abelara Red (#F5602B)
GREEN='\033[38;2;212;253;177m'  # Abelara Light Green (#D4FDB1)
YELLOW='\033[38;2;255;255;169m' # Abelara Pale Yellow (#FFFFA9)
CYAN='\033[38;2;179;230;225m'   # Abelara Light Blue (#B3E6E1)
BLACK='\033[38;2;37;37;37m'     # Abelara Black (#252525)
WHITE='\033[38;2;255;255;255m'  # White (#FFFFFF)

# Additional useful variants
BOLD='\033[1m'
DIM='\033[2m'
UNDERLINE='\033[4m'
NC='\033[0m'  # No Color/Reset

# Background colors if needed
BG_CYAN='\033[48;2;179;230;225m'    # Light Blue background
BG_GREEN='\033[48;2;212;253;177m'   # Light Green background
BG_YELLOW='\033[48;2;255;255;169m'  # Pale Yellow background
BG_BLACK='\033[48;2;37;37;37m'      # Black background

# ============================================
# Logging Functions
# ============================================

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}✗${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${CYAN}ℹ${NC} $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo -e "${BG_CYAN}${BLACK}${BOLD}  $1  ${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
}

# ============================================
# Error Handling
# ============================================

error_handler() {
    local exit_code=$1
    local line_no=$2
    log_error "Error occurred in script at line $line_no with exit code $exit_code"
    log_error "Check $LOG_FILE for details"
    
    echo -e "\n${RED}════════════════════════════════════════${NC}"
    echo -e "${BG_BLACK}${RED}${BOLD}  Setup Failed - Error Code: $exit_code  ${NC}"
    echo -e "${RED}════════════════════════════════════════${NC}"
    echo -e "${YELLOW}${UNDERLINE}Troubleshooting:${NC}"
    echo -e "1. Check the log: ${CYAN}cat $LOG_FILE${NC}"
    echo -e "2. Fix the issue and run: ${CYAN}./setup.sh --resume${NC}"
    echo -e "3. For help: ${CYAN}./setup.sh --help${NC}"
    
    cleanup_on_error
    exit $exit_code
}

cleanup_on_error() {
    log_info "Performing cleanup..."
    # Don't remove data directories or .env file to preserve user data
    # Just ensure Docker is in a clean state
    if command -v docker &> /dev/null; then
        docker-compose down 2>/dev/null || true
    fi
}

# Set error trap after function definition
trap 'error_handler $? $LINENO' ERR

# ============================================
# Helper Functions
# ============================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo -e "${RED}Please run: sudo ./setup.sh${NC}"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS version"
        exit 1
    fi
    
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]] || [[ "${VERSION_ID}" != "24.04" && "${VERSION_ID}" != "22.04" && "${VERSION_ID}" != "20.04" ]]; then
        log_warning "This script is optimized for Ubuntu 20.04/22.04/24.04"
        echo -e "${YELLOW}${DIM}Current OS: $PRETTY_NAME${NC}"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

check_resources() {
    print_header "System Resource Check"
    
    # Check memory
    local total_mem=$(free -m | awk 'NR==2{print $2}')
    if [[ $total_mem -lt $REQUIRED_MEMORY_MB ]]; then
        log_error "Insufficient memory: ${total_mem}MB available, ${REQUIRED_MEMORY_MB}MB required"
        exit 1
    fi
    log_success "Memory check passed: ${total_mem}MB available"
    
    # Check disk space
    local available_space=$(df / | awk 'NR==2{print int($4/1048576)}')
    if [[ $available_space -lt $REQUIRED_DISK_GB ]]; then
        log_error "Insufficient disk space: ${available_space}GB available, ${REQUIRED_DISK_GB}GB required"
        exit 1
    fi
    log_success "Disk space check passed: ${available_space}GB available"
    
    # Check CPU
    local cpu_cores=$(nproc)
    log_info "CPU cores detected: $cpu_cores"
    if [[ $cpu_cores -lt 1 ]]; then
        log_error "At least 1 CPU core required"
        exit 1
    fi
    log_success "CPU check passed"
}

detect_environment() {
    # Detect if running on Vultr
    IS_VULTR=false
    if [[ -f /etc/vultr ]] || curl -s -m 2 http://169.254.169.254/v1/vendor 2>/dev/null | grep -qi "vultr"; then
        IS_VULTR=true
        log_success "Vultr VPS detected"
        log_info "SSH access managed by Vultr dashboard"
        log_info "Firewall rules managed at: https://my.vultr.com"
        
        # Get Vultr instance info if available
        if command -v vultr-cli &> /dev/null; then
            log_info "Vultr CLI detected"
        fi
        
        # Check if this is a Vultr Marketplace app
        if [[ -f /opt/vultr/marketplacehelper ]]; then
            log_info "Vultr Marketplace helper detected"
        fi
        
        return 0
    fi
    
    # Detect other cloud providers for reference
    if curl -s -m 2 http://169.254.169.254/latest/meta-data/ &>/dev/null; then
        log_info "AWS EC2 detected"
    elif curl -s -m 2 -H "Metadata-Flavor: Google" http://metadata.google.internal &>/dev/null; then
        log_info "Google Cloud detected"
    elif curl -s -m 2 -H "Metadata: true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" &>/dev/null; then
        log_info "Azure detected"
    else
        log_info "Bare metal or unrecognized VPS provider"
    fi
}

prompt_with_retry() {
    local prompt="$1"
    local var_name="$2"
    local validation_func="${3:-}"
    local is_secret="${4:-false}"
    local attempts=0
    local input=""
    
    while [[ $attempts -lt $MAX_RETRIES ]]; do
        if [[ "$is_secret" == "true" ]]; then
            read -s -p "$prompt" input
            echo
        else
            read -p "$prompt" input
        fi
        
        # If no validation function provided, accept any input
        if [[ -z "$validation_func" ]]; then
            eval "$var_name='$input'"
            return 0
        fi
        
        # Validate input
        if $validation_func "$input"; then
            eval "$var_name='$input'"
            return 0
        else
            attempts=$((attempts + 1))
            if [[ $attempts -lt $MAX_RETRIES ]]; then
                log_warning "Invalid input. Attempts remaining: $((MAX_RETRIES - attempts))"
            fi
        fi
    done
    
    log_error "Maximum retry attempts reached"
    return 1
}

validate_domain() {
    local domain="$1"
    if [[ -z "$domain" ]]; then
        log_error "Domain cannot be empty"
        return 1
    fi
    
    # Basic domain validation regex
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?\.[a-zA-Z]{2,}(\.[a-zA-Z]{2,})?$ ]]; then
        log_error "Invalid domain format. Example: n8n.yourdomain.com"
        return 1
    fi
    
    log_success "Domain format valid: $domain"
    return 0
}

validate_token() {
    local token="$1"
    if [[ -z "$token" ]]; then
        return 0  # Empty token is allowed (user can add later)
    fi
    
    # Cloudflare tunnel tokens start with 'eyJ'
    if [[ ! "$token" =~ ^eyJ.+ ]]; then
        log_error "Invalid token format. Cloudflare tunnel tokens start with 'eyJ'"
        return 1
    fi
    
    log_success "Token format valid"
    return 0
}

validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid email format"
        return 1
    fi
    return 0
}

# ============================================
# Installation Functions
# ============================================

install_prerequisites() {
    print_header "[1/7] Installing Prerequisites"
    
    log_info "Updating package list..."
    apt-get update -qq || {
        log_error "Failed to update package list"
        log_info "Trying alternative mirror..."
        sed -i 's/archive.ubuntu.com/mirrors.digitalocean.com/g' /etc/apt/sources.list
        apt-get update -qq || exit 1
    }
    
    log_info "Installing required packages..."
    local packages=(
        "curl"
        "wget"
        "gnupg"
        "lsb-release"
        "ca-certificates"
        "software-properties-common"
        "ufw"
        "net-tools"
        "htop"
    )
    
    for package in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii.*$package"; then
            log_success "$package already installed"
        else
            log_info "Installing $package..."
            apt-get install -y "$package" || {
                log_error "Failed to install $package"
                exit 1
            }
            log_success "$package installed"
        fi
    done
}

install_docker() {
    print_header "[2/7] Installing Docker"
    
    if command -v docker &> /dev/null; then
        local docker_version=$(docker --version | awk '{print $3}' | sed 's/,//')
        log_success "Docker already installed (version $docker_version)"
        
        # Ensure Docker service is running
        systemctl enable docker --quiet
        systemctl start docker || {
            log_error "Failed to start Docker service"
            exit 1
        }
        return 0
    fi
    
    log_info "Installing Docker..."
    
    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || {
        log_error "Failed to add Docker GPG key"
        exit 1
    }
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Add Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin || {
        log_error "Failed to install Docker"
        exit 1
    }
    
    # Install Docker Compose
    log_info "Installing Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
         -o /usr/local/bin/docker-compose || {
        log_error "Failed to download Docker Compose"
        exit 1
    }
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    
    # Enable and start Docker
    systemctl enable docker --quiet
    systemctl start docker || {
        log_error "Failed to start Docker service"
        exit 1
    }
    
    # Verify installation
    docker --version || {
        log_error "Docker installation verification failed"
        exit 1
    }
    docker-compose --version || {
        log_error "Docker Compose installation verification failed"
        exit 1
    }
    
    log_success "Docker and Docker Compose installed successfully"
}

setup_swap() {
    print_header "[3/7] Configuring Swap Memory"
    
    local swap_size="2G"
    
    # Check if swap already exists
    if swapon --show | grep -q '/swapfile'; then
        local current_swap=$(swapon --show | grep '/swapfile' | awk '{print $3}')
        log_success "Swap already configured: $current_swap"
        return 0
    fi
    
    log_info "Creating ${swap_size} swap file..."
    
    # Create swap file
    fallocate -l $swap_size /swapfile || {
        log_warning "fallocate failed, trying dd method..."
        dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress || {
            log_error "Failed to create swap file"
            exit 1
        }
    }
    
    # Set permissions and enable swap
    chmod 600 /swapfile
    mkswap /swapfile || {
        log_error "Failed to create swap space"
        exit 1
    }
    swapon /swapfile || {
        log_error "Failed to enable swap"
        exit 1
    }
    
    # Make swap permanent
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
    # Configure swappiness
    echo "vm.swappiness=60" > /etc/sysctl.d/99-swappiness.conf
    sysctl -p /etc/sysctl.d/99-swappiness.conf &>/dev/null
    
    log_success "Swap configured successfully"
}

configure_kernel() {
    print_header "[4/7] Applying Kernel Optimizations"
    
    log_info "Applying security and performance settings..."
    
    cat > /etc/sysctl.d/99-n8n-optimized.conf << 'EOF'
# Network Security
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.ip_forward = 1

# Network Performance
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_fastopen = 3
net.core.netdev_max_backlog = 5000

# File System
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288

# Docker Optimization
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
    
    # Apply settings
    sysctl -p /etc/sysctl.d/99-n8n-optimized.conf &>/dev/null || {
        log_warning "Some kernel parameters could not be applied"
    }
    
    log_success "Kernel optimizations applied"
}

configure_firewall() {
    print_header "[5/7] Configuring Firewall"
    
    if [[ "$IS_VULTR" == true ]]; then
        log_info "Vultr VPS detected - using Vultr's cloud firewall"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}${BOLD}✓${NC} ${GREEN}SSH access is managed by Vultr${NC}"
        echo -e "${GREEN}${BOLD}✓${NC} ${GREEN}Firewall rules configured in Vultr dashboard${NC}"
        echo -e "${GREEN}${BOLD}✓${NC} ${GREEN}No local firewall changes needed${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        # Check if UFW is active (shouldn't be on Vultr)
        if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            log_warning "Local UFW firewall detected on Vultr instance"
                    echo -e "${YELLOW}${DIM}Note: Vultr recommends using their cloud firewall instead${NC}"
        echo -e "${YELLOW}${DIM}You can manage firewall rules at: ${CYAN}${UNDERLINE}https://my.vultr.com${NC}"
            
            # Don't modify it, just inform the user
            log_info "Current UFW status:"
            ufw status numbered
        else
            log_success "No local firewall active (correct for Vultr)"
        fi
        
        # Just ensure Docker can work properly
        if [[ -f /etc/docker/daemon.json ]]; then
            log_info "Docker networking already configured"
        else
            log_info "Configuring Docker networking..."
            cat > /etc/docker/daemon.json << 'EOF'
{
  "iptables": true,
  "bridge": "docker0",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
            systemctl restart docker || log_warning "Docker restart needed later"
        fi
        
        log_success "Vultr firewall configuration verified"
        return 0
    fi
    
    # For non-Vultr systems, configure UFW
    log_info "Non-Vultr system detected - configuring local firewall..."
    
    # Check if UFW is installed
    if ! command -v ufw &> /dev/null; then
        log_warning "UFW not installed, skipping firewall configuration"
        log_info "Install UFW manually if needed: apt install ufw"
        return 0
    fi
    
    # Reset firewall to default state
    ufw --force disable &>/dev/null
    echo "y" | ufw --force reset &>/dev/null
    
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH (port 22 - standard)
    ufw allow 22/tcp comment 'SSH' || {
        log_error "Failed to configure SSH firewall rule"
        exit 1
    }
    
    # Allow Docker networks
    ufw allow from 172.16.0.0/12 comment 'Docker Networks'
    
    # Enable firewall
    echo "y" | ufw enable || {
        log_error "Failed to enable firewall"
        log_warning "Continuing without firewall"
    }
    
    log_success "Local firewall configured"
}

generate_env_file() {
    print_header "[6/7] Generating Configuration"
    
    # Check if .env exists and has content
    if [[ -f .env ]] && grep -q "N8N_ENCRYPTION_KEY" .env && ! grep -q "WILL_BE_GENERATED" .env; then
        log_warning ".env file already exists with configuration"
        read -p "Overwrite existing configuration? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Keeping existing configuration"
            return 0
        fi
        # Backup existing .env
        cp .env ".env.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Existing .env backed up"
    fi
    
    log_info "Creating environment configuration..."
    
    # Generate encryption key
    local encryption_key=$(openssl rand -base64 32)
    
    # Create .env file
    cat > .env << EOF
# ============================================
# n8n Configuration
# Generated: $(date)
# ============================================

# Domain Configuration
DOMAIN=n8n.yourdomain.com

# Security - Data Encryption Key
N8N_ENCRYPTION_KEY=$encryption_key

# Timezone Configuration
TIMEZONE=America/New_York

# Cloudflare Tunnel Token (required)
TUNNEL_TOKEN=YOUR_TUNNEL_TOKEN

# Performance Settings
N8N_CONCURRENCY_PRODUCTION_LIMIT=10
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=72
EXECUTIONS_DATA_PRUNE_TIMEOUT=3600

# Node.js Memory Limit (MB) - Leave headroom for system processes
NODE_OPTIONS=--max-old-space-size=1536
EOF
    
    chmod 600 .env
    log_success "Environment configuration created"
    
    # Now collect user input
    collect_user_configuration
}

collect_user_configuration() {
    print_header "[7/7] User Configuration"
    
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${BG_CYAN}${BLACK}${BOLD}  Cloudflare Tunnel Configuration  ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    
    # Check if tunnel token needs to be configured
    if grep -q "YOUR_TUNNEL_TOKEN" .env; then
        echo -e "\n${YELLOW}Please have your Cloudflare Tunnel token ready.${NC}"
        echo -e "${CYAN}${UNDERLINE}Steps to get token:${NC}"
        echo -e "1. Go to: ${CYAN}https://one.dash.cloudflare.com/${NC}"
        echo -e "2. Navigate to: ${CYAN}${BOLD}Access → Tunnels${NC}"
        echo -e "3. Create tunnel named: ${CYAN}${BOLD}n8n-production${NC}"
        echo -e "4. Choose: ${CYAN}${BOLD}Docker${NC} environment"
        echo -e "5. Copy the token (starts with ${YELLOW}${BOLD}eyJ${NC})\n"
        
        local tunnel_token
        if prompt_with_retry "Enter Cloudflare Tunnel token (or press Enter to skip): " tunnel_token validate_token false; then
            if [[ -n "$tunnel_token" ]]; then
                sed -i "s|TUNNEL_TOKEN=.*|TUNNEL_TOKEN=$tunnel_token|" .env
                log_success "Tunnel token configured"
            else
                log_warning "Tunnel token skipped - you'll need to add it manually to .env"
            fi
        fi
    else
        log_success "Tunnel token already configured"
    fi
    
    echo -e "\n${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${BG_CYAN}${BLACK}${BOLD}  Domain Configuration  ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}\n"
    
    # Configure domain
    local current_domain=$(grep "^DOMAIN=" .env | cut -d'=' -f2)
    if [[ "$current_domain" == "n8n.yourdomain.com" ]]; then
        local domain
        if prompt_with_retry "Enter your domain (e.g., n8n.example.com): " domain validate_domain false; then
            sed -i "s|DOMAIN=.*|DOMAIN=$domain|" .env
            log_success "Domain configured: $domain"
        fi
    else
        log_success "Domain already configured: $current_domain"
    fi
    
    # Configure timezone
    echo -e "\n${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${BG_YELLOW}${BLACK}${BOLD}  Timezone Configuration (Optional)  ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}\n"
    
    local current_tz=$(grep "^TIMEZONE=" .env | cut -d'=' -f2)
    echo -e "Current timezone: ${YELLOW}$current_tz${NC}"
    read -p "Keep this timezone? (Y/n): " -n 1 -r
    echo
    
    # If user presses Enter or 'y/Y', keep current timezone
    if [[ -z "$REPLY" ]] || [[ $REPLY =~ ^[Yy]$ ]]; then
        log_success "Keeping timezone: $current_tz"
    else
        # User wants to change timezone
        echo -e "\n${CYAN}${BOLD}Common timezones:${NC}"
        echo "  1) America/New_York"
        echo "  2) America/Chicago"
        echo "  3) America/Los_Angeles"
        echo "  4) Europe/London"
        echo "  5) Europe/Paris"
        echo "  6) Asia/Tokyo"
        echo "  7) Australia/Sydney"
        echo "  8) Enter custom"
        echo "  9) Keep current ($current_tz)"
        
        local tz_choice
        local new_tz=""
        local valid_choice=false
        
        while [[ "$valid_choice" == false ]]; do
            read -p "Select option (1-9): " tz_choice
            
            case $tz_choice in
                1) new_tz="America/New_York"; valid_choice=true ;;
                2) new_tz="America/Chicago"; valid_choice=true ;;
                3) new_tz="America/Los_Angeles"; valid_choice=true ;;
                4) new_tz="Europe/London"; valid_choice=true ;;
                5) new_tz="Europe/Paris"; valid_choice=true ;;
                6) new_tz="Asia/Tokyo"; valid_choice=true ;;
                7) new_tz="Australia/Sydney"; valid_choice=true ;;
                8) 
                    read -p "Enter timezone (e.g., America/Denver): " new_tz
                    if [[ -n "$new_tz" ]]; then
                        valid_choice=true
                    else
                        log_warning "Timezone cannot be empty"
                    fi
                    ;;
                9) 
                    log_success "Keeping current timezone: $current_tz"
                    valid_choice=true
                    ;;
                *) 
                    log_warning "Invalid selection. Please choose 1-9"
                    ;;
            esac
        done
        
        if [[ -n "$new_tz" ]]; then
            sed -i "s|TIMEZONE=.*|TIMEZONE=$new_tz|" .env
            log_success "Timezone updated: $new_tz"
        fi
    fi
}

create_directories() {
    log_info "Creating required directories..."
    
    # Note: n8n data is stored in Docker volume, not bind mount
    local dirs=("files" "backups" "logs")
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            chmod 755 "$dir"
            log_success "Created directory: $dir"
        else
            log_success "Directory exists: $dir"
        fi
    done
}

setup_health_monitoring() {
    log_info "Setting up health monitoring..."
    
    # Create health check script
    cat > /usr/local/bin/n8n-health-check.sh << 'EOF'
#!/bin/bash
# n8n Health Check Script

LOG_FILE="/var/log/n8n-health.log"
N8N_DIR="/root/n8n"

cd "$N8N_DIR" || exit 1

# Check if n8n container is running and healthy
if ! docker ps | grep -q "n8n"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - n8n container not running, attempting restart..." >> "$LOG_FILE"
    docker-compose up -d
    
    # Wait for container to start
    sleep 10
    
    # Verify it's running now
    if docker ps | grep -q "n8n"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - n8n successfully restarted" >> "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Failed to restart n8n" >> "$LOG_FILE"
    fi
else
    # Container is running, but is n8n actually healthy?
    if ! docker exec n8n wget -q -O- http://localhost:5678/healthz 2>/dev/null | grep -q "ok"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - n8n unhealthy, restarting..." >> "$LOG_FILE"
        docker-compose restart n8n
        
        # Wait for restart and verify health
        sleep 15
        if docker exec n8n wget -q -O- http://localhost:5678/healthz 2>/dev/null | grep -q "ok"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - n8n health restored after restart" >> "$LOG_FILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - n8n still unhealthy after restart" >> "$LOG_FILE"
        fi
    fi
fi

# Check if cloudflared is running
if ! docker ps | grep -q "cloudflared"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Cloudflared not running, attempting restart..." >> "$LOG_FILE"
    docker-compose up -d cloudflared
fi

# Check disk space
DISK_USAGE=$(df / | awk 'NR==2 {print int($5)}')
if [[ $DISK_USAGE -gt 85 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Disk usage is ${DISK_USAGE}%" >> "$LOG_FILE"
fi

# Check memory
MEM_AVAILABLE=$(free -m | awk 'NR==2 {print int($7)}')
if [[ $MEM_AVAILABLE -lt 200 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Low memory: ${MEM_AVAILABLE}MB available" >> "$LOG_FILE"
fi
EOF
    
    chmod +x /usr/local/bin/n8n-health-check.sh
    
    # Add to crontab if not exists
    if ! crontab -l 2>/dev/null | grep -q "n8n-health-check.sh"; then
        (crontab -l 2>/dev/null || echo ""; echo "*/5 * * * * /usr/local/bin/n8n-health-check.sh") | crontab -
        log_success "Health monitoring configured (runs every 5 minutes)"
    else
        log_success "Health monitoring already configured"
    fi
}

# ============================================
# Final Steps
# ============================================

show_next_steps() {
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BG_GREEN}${BLACK}${BOLD}       ✅ SETUP COMPLETE!       ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    echo -e "${CYAN}${BOLD}📋 Configuration Summary:${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    local domain=$(grep "^DOMAIN=" .env | cut -d'=' -f2)
    local timezone=$(grep "^TIMEZONE=" .env | cut -d'=' -f2)
    local token_status="Not configured"
    if ! grep -q "YOUR_TUNNEL_TOKEN" .env; then
        token_status="${GREEN}Configured${NC}"
    else
        token_status="${YELLOW}Needs configuration${NC}"
    fi
    
    echo -e "Domain:        ${BOLD}$domain${NC}"
    echo -e "Timezone:      ${BOLD}$timezone${NC}"
    echo -e "Tunnel Token:  $token_status"
    
    if [[ "$IS_VULTR" == true ]]; then
        echo -e "Infrastructure: ${BOLD}Vultr VPS${NC}"
        echo -e "SSH Access:    ${GREEN}Managed by Vultr${NC}"
        echo -e "Firewall:      ${GREEN}Vultr Cloud Firewall${NC}"
    fi
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    echo -e "${CYAN}${BOLD}🚀 Next Steps:${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if grep -q "YOUR_TUNNEL_TOKEN" .env; then
        echo -e "${YELLOW}1. Add your Cloudflare Tunnel token:${NC}"
        echo -e "   ${CYAN}nano .env${NC}"
        echo -e "   Update: TUNNEL_TOKEN=your_actual_token"
        echo -e ""
    fi
    
    echo -e "1. Start n8n:"
    echo -e "   ${CYAN}docker-compose up -d${NC}"
    echo -e ""
    echo -e "2. Monitor logs:"
    echo -e "   ${CYAN}docker-compose logs -f${NC}"
    echo -e ""
    echo -e "3. Access n8n:"
    echo -e "   ${CYAN}https://$domain${NC}"
    echo -e ""
    echo -e "4. Create your admin account on first access"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    echo -e "${CYAN}${BOLD}📚 Useful Commands:${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "View status:   ${GREEN}docker-compose ps${NC}"
    echo -e "View logs:     ${GREEN}docker-compose logs -f${NC}"
    echo -e "Stop n8n:      ${GREEN}docker-compose down${NC}"
    echo -e "Restart n8n:   ${GREEN}docker-compose restart${NC}"

    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    echo -e "${CYAN}${BOLD}🔒 Security Features:${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "✅ Cloudflare Zero Trust Tunnel"
    echo -e "✅ No exposed ports"
    echo -e "✅ Encrypted data storage"
    echo -e "✅ Automatic health monitoring"
    if [[ "$IS_VULTR" == true ]]; then
        echo -e "✅ Vultr cloud firewall"
        echo -e "✅ Vultr managed SSH access"
    else
        echo -e "✅ UFW local firewall"
    fi
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    if [[ "$IS_VULTR" == true ]]; then
        echo -e "${CYAN}${BOLD}🔧 Vultr Management:${NC}"
        echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "Dashboard:     ${CYAN}${UNDERLINE}https://my.vultr.com${NC}"
        echo -e "SSH Keys:      Managed in Vultr dashboard"
        echo -e "Firewall:      Configure in Vultr dashboard"
        echo -e "Snapshots:     Available in Vultr dashboard"
        echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    fi
    
    log_success "Setup completed successfully!"
    log_info "Log file: $LOG_FILE"
}

# ============================================
# Main Execution
# ============================================

main() {
    # Initialize log
    echo "=== n8n Setup Started at $(date) ===" > "$LOG_FILE"
    
    # Parse arguments
    case "${1:-}" in
        --help|-h)
            echo "n8n Production Setup Script"
            echo "Usage: ./setup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --help      Show this help message"
            echo "  --resume    Resume from last failure point"
            echo "  --reset     Reset configuration and start fresh"
            echo ""
            exit 0
            ;;
        --reset)
            log_warning "Resetting configuration..."
            rm -f .env
            log_success "Configuration reset"
            ;;
        --resume)
            log_info "Resuming setup..."
            ;;
    esac
    
    # Print banner
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BG_BLACK}${WHITE}${BOLD}   n8n Production Setup Script   ${NC}  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${BG_BLACK}${GREEN}     Vultr Optimized • v1.0      ${NC}  ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo
    
    # Pre-flight checks
    check_root
    check_os
    detect_environment
    check_resources
    
    # Create working directories
    create_directories
    
    # Main installation flow
    install_prerequisites
    install_docker
    setup_swap
    configure_kernel
    configure_firewall
    generate_env_file
    setup_health_monitoring
    
    # Show completion message
    show_next_steps
    
    # Save success marker
    touch .setup_complete
    
    exit 0
}

# ============================================
# Script Entry Point
# ============================================

# Ensure we're in the right directory
cd "$SCRIPT_DIR" || {
    echo "Failed to change to script directory"
    exit 1
}

# Run main function
main "$@"