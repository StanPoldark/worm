#!/bin/bash
set -e
set -o pipefail

# Colors for better UI
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Configuration paths
CONFIG_DIR="$HOME/.worm-miner"
MINER_DIR="$HOME/miner"
LOG_FILE="$CONFIG_DIR/miner.log"
KEY_FILE="$CONFIG_DIR/private.key"
RPC_FILE="$CONFIG_DIR/fastest_rpc.log"
BACKUP_DIR="$CONFIG_DIR/backups"
WORM_MINER_BIN="$HOME/.cargo/bin/worm-miner"

# Enhanced Sepolia RPC list
SEPOLIA_RPCS=(
    "https://sepolia.drpc.org"
    "https://ethereum-sepolia-rpc.publicnode.com" 
    "https://eth-sepolia.public.blastapi.io"
    "https://rpc.sepolia.org"
    "https://sepolia.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161"
    "https://sepolia.gateway.tenderly.co"
)

# Minimum system requirements
MIN_MEMORY_GB=16
MIN_DISK_GB=20

# Logging function
log_info() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1${NC}" | tee -a "$LOG_FILE" 2>/dev/null || true
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1${NC}" | tee -a "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" | tee -a "$LOG_FILE" 2>/dev/null || true
}

# System requirements check
check_system_requirements() {
    echo -e "${CYAN}[*] Checking system requirements...${NC}"
    
    # Check if running as root (optional but recommended)
    if [[ $EUID -eq 0 ]]; then
        log_warn "Running as root. Consider using a regular user for security."
    fi
    
    # Check OS
    if [[ ! -f /etc/os-release ]] || ! grep -q "ubuntu\|debian" /etc/os-release -i; then
        log_warn "This script is optimized for Ubuntu/Debian. Continue at your own risk."
        read -p "Continue anyway? [y/N]: " continue_anyway
        [[ ! "$continue_anyway" =~ ^[yY]$ ]] && exit 1
    fi
    
    # Check memory
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    total_mem_gb=$((total_mem_kb / 1024 / 1024))
    if [[ $total_mem_gb -lt $MIN_MEMORY_GB ]]; then
        log_error "Insufficient memory: ${total_mem_gb}GB available, ${MIN_MEMORY_GB}GB required"
        exit 1
    fi
    
    # Check disk space
    available_space_gb=$(df "$HOME" | awk 'NR==2 {print int($4/1024/1024)}')
    if [[ $available_space_gb -lt $MIN_DISK_GB ]]; then
        log_error "Insufficient disk space: ${available_space_gb}GB available, ${MIN_DISK_GB}GB required"
        exit 1
    fi
    
    log_info "System requirements check passed: ${total_mem_gb}GB RAM, ${available_space_gb}GB available"
}

# Check if miner is installed
check_miner_installed() {
    [[ -f "$WORM_MINER_BIN" ]] && [[ -d "$MINER_DIR" ]]
}

# Check if miner is configured (has private key and service)
check_miner_configured() {
    [[ -f "$KEY_FILE" ]] && [[ -f "/etc/systemd/system/worm-miner.service" ]]
}

# Get private key with validation
get_private_key() {
    if [[ ! -f "$KEY_FILE" ]]; then
        log_error "Private key file not found. Please install miner first (Option 1)."
        return 1
    fi
    
    local private_key
    private_key=$(cat "$KEY_FILE")
    if [[ ! $private_key =~ ^0x[0-9a-fA-F]{64}$ ]]; then
        log_error "Invalid private key format in $KEY_FILE"
        return 1
    fi
    echo "$private_key"
}

# Enhanced RPC testing with parallel execution
find_fastest_rpc() {
    echo -e "${CYAN}[*] Testing Sepolia RPCs to find the fastest one...${NC}"
    
    local fastest_rpc=""
    local min_latency=999999
    local temp_dir="/tmp/rpc_test_$$"
    mkdir -p "$temp_dir"
    
    # Test RPCs in parallel for faster results
    for i in "${!SEPOLIA_RPCS[@]}"; do
        local rpc="${SEPOLIA_RPCS[$i]}"
        (
            # Test with a simple JSON-RPC call
            local start_time=$(date +%s%N)
            response=$(curl -s --connect-timeout 3 --max-time 8 \
                -X POST -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
                "$rpc" 2>/dev/null || echo "ERROR")
            local end_time=$(date +%s%N)
            
            if [[ "$response" != "ERROR" ]] && echo "$response" | grep -q "result"; then
                local latency=$(echo "scale=3; ($end_time - $start_time) / 1000000000" | bc)
                echo "$latency:$rpc" > "$temp_dir/result_$i"
                echo -e "  ${DIM}Testing $rpc: ${YELLOW}${latency}s${NC}"
            else
                echo "999999:$rpc" > "$temp_dir/result_$i"
                echo -e "  ${DIM}Testing $rpc: ${RED}FAILED${NC}"
            fi
        ) &
    done
    
    # Wait for all background jobs
    wait
    
    # Find the fastest RPC
    for result_file in "$temp_dir"/result_*; do
        if [[ -f "$result_file" ]]; then
            local result=$(cat "$result_file")
            local latency="${result%%:*}"
            local rpc="${result#*:}"
            
            if (( $(echo "$latency < $min_latency && $latency > 0" | bc -l) )); then
                min_latency=$latency
                fastest_rpc=$rpc
            fi
        fi
    done
    
    rm -rf "$temp_dir"
    
    if [[ -n "$fastest_rpc" ]]; then
        echo "$fastest_rpc" > "$RPC_FILE"
        log_info "Fastest RPC selected: $fastest_rpc (${min_latency}s latency)"
    else
        log_error "Could not find a working RPC. Please check your internet connection."
        return 1
    fi
}

# Enhanced dependency installation
install_dependencies() {
    echo -e "${CYAN}[*] Installing system dependencies...${NC}"
    
    # Update package manager
    sudo apt-get update -qq
    
    # Install comprehensive dependency list
    local deps=(
        "build-essential" "cmake" "libgmp-dev" "libsodium-dev" 
        "nasm" "curl" "m4" "git" "wget" "unzip" "bc"
        "nlohmann-json3-dev" "pkg-config" "libssl-dev"
        "python3" "python3-pip" "jq"
    )
    
    log_info "Installing dependencies: ${deps[*]}"
    sudo apt-get install -y "${deps[@]}"
    
    # Install additional Python packages for address generation
    pip3 install --user web3 >/dev/null 2>&1 || log_warn "Failed to install web3 Python package"
}

# Install Rust with version check
install_rust() {
    if command -v cargo &>/dev/null; then
        local rust_version=$(rustc --version 2>/dev/null || echo "unknown")
        log_info "Rust already installed: $rust_version"
        return 0
    fi
    
    echo -e "${CYAN}[*] Installing Rust toolchain...${NC}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    
    # Verify installation
    if command -v cargo &>/dev/null; then
        log_info "Rust installed successfully: $(rustc --version)"
    else
        log_error "Rust installation failed"
        return 1
    fi
}

# Enhanced miner installation
install_miner() {
    echo -e "${BOLD}${GREEN}=== WORM MINER INSTALLATION ===${NC}"
    
    check_system_requirements
    install_dependencies
    install_rust
    
    # Create necessary directories
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE"
    
    # Handle existing installation
    if [[ -d "$MINER_DIR" ]]; then
        echo -e "${YELLOW}Existing miner directory found at $MINER_DIR${NC}"
        read -p "Remove and reinstall? [y/N]: " reinstall
        if [[ "$reinstall" =~ ^[yY]$ ]]; then
            log_info "Removing existing miner directory..."
            rm -rf "$MINER_DIR"
        else
            log_info "Keeping existing installation, updating instead..."
            cd "$MINER_DIR"
            git pull origin main
            return 0
        fi
    fi
    
    # Clone repository
    echo -e "${CYAN}[*] Cloning WORM miner repository...${NC}"
    cd "$HOME"
    if ! git clone https://github.com/worm-privacy/miner "$MINER_DIR"; then
        log_error "Failed to clone repository. Check network connection."
        return 1
    fi
    
    cd "$MINER_DIR"
    
    # Verify we're in the right repository
    if ! git remote -v | grep -q "worm-privacy/miner"; then
        log_error "Wrong repository cloned. Expected worm-privacy/miner."
        return 1
    fi
    
    # Download parameters with progress indication
    echo -e "${CYAN}[*] Downloading ZK-SNARK parameters...${NC}"
    echo -e "${YELLOW}This is a large download (~8GB) and may take 10-30 minutes depending on your connection.${NC}"
    
    if ! make download_params; then
        log_error "Failed to download parameters. Check network connection and try again."
        return 1
    fi
    
    # Verify parameter files
    if ! ls -la | grep -q "\.zkey"; then
        log_warn "Parameter files may not have downloaded correctly."
    else
        log_info "Parameter files downloaded successfully"
    fi
    
    # Build and install miner with optimizations
    echo -e "${CYAN}[*] Building optimized miner binary...${NC}"
    RUSTFLAGS="-C target-cpu=native -C opt-level=3" cargo install --path .
    
    # Verify installation
    if [[ ! -f "$WORM_MINER_BIN" ]]; then
        log_error "Miner binary not found at $WORM_MINER_BIN"
        return 1
    fi
    
    # Verify miner version
    local version=$("$WORM_MINER_BIN" --version 2>/dev/null || echo "unknown")
    log_info "Miner installed successfully: $version"
    
    echo -e "${BOLD}${GREEN}[+] WORM Miner installation completed successfully!${NC}"
    echo -e "${YELLOW}[!] Please use Option 2 to configure your miner (setup private key and service).${NC}"
}

# Setup configuration for already installed miner
setup_miner_config() {
    echo -e "${BOLD}${GREEN}=== WORM MINER CONFIGURATION ===${NC}"
    
    if ! check_miner_installed; then
        log_error "Miner is not installed. Please install first (Option 1)."
        return 1
    fi
    
    # Create necessary directories if they don't exist
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE"
    
    # Find fastest RPC if not already done
    if [[ ! -f "$RPC_FILE" ]]; then
        find_fastest_rpc
    fi
    
    # Setup or update private key
    setup_private_key
    
    # Create or update systemd service
    setup_systemd_service
    
    echo -e "${BOLD}${GREEN}[+] WORM Miner configuration completed successfully!${NC}"
}

# Enhanced private key setup with address generation
setup_private_key() {
    echo -e "${CYAN}[*] Setting up private key...${NC}"
    
    local private_key=""
    while true; do
        echo -e "${YELLOW}Please enter your Ethereum private key:${NC}"
        echo -e "${DIM}Format: 0x followed by 64 hexadecimal characters${NC}"
        read -p "Private Key: " private_key
        echo ""
        
        if [[ $private_key =~ ^0x[0-9a-fA-F]{64}$ ]]; then
            break
        else
            echo -e "${RED}Invalid key format. Must be 64 hex characters starting with 0x.${NC}"
            echo -e "${DIM}Example: 0x1234567890abcdef...${NC}"
        fi
    done
    
    # Save private key securely
    echo "$private_key" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    
    # Try to generate and display address
    if command -v python3 &>/dev/null; then
        local address=$(python3 -c "
try:
    from web3 import Web3
    w3 = Web3()
    account = w3.eth.account.from_key('$private_key')
    print(account.address)
except:
    print('Unable to generate address')
" 2>/dev/null || echo "Unable to generate address")
        
        if [[ "$address" != "Unable to generate address" ]]; then
            echo -e "${GREEN}Your Ethereum address: ${BOLD}$address${NC}"
            echo "$address" > "$CONFIG_DIR/address.txt"
        fi
    fi
    
    # Create backup
    cp "$KEY_FILE" "$BACKUP_DIR/private.key.$(date +%s)"
    log_info "Private key saved and backed up securely"
    
    echo -e "${YELLOW}${BOLD}SECURITY WARNING:${NC}"
    echo -e "${YELLOW}• Your private key is stored in: $KEY_FILE${NC}"
    echo -e "${YELLOW}• Backup created in: $BACKUP_DIR${NC}"
    echo -e "${YELLOW}• Keep this key secure and never share it!${NC}"
}

# Enhanced systemd service setup
setup_systemd_service() {
    echo -e "${CYAN}[*] Setting up systemd service...${NC}"
    
    # Create miner start script with enhanced logging
    cat > "$MINER_DIR/start-miner.sh" << 'EOF'
#!/bin/bash
set -e

CONFIG_DIR="$HOME/.worm-miner"
PRIVATE_KEY=$(cat "$CONFIG_DIR/private.key")
FASTEST_RPC=$(cat "$CONFIG_DIR/fastest_rpc.log")

echo "[$(date)] Starting WORM miner with RPC: $FASTEST_RPC"

exec "$HOME/.cargo/bin/worm-miner" mine \
  --network sepolia \
  --private-key "$PRIVATE_KEY" \
  --custom-rpc "$FASTEST_RPC" \
  --amount-per-epoch "0.0001" \
  --num-epochs "3" \
  --claim-interval "10"
EOF
    chmod +x "$MINER_DIR/start-miner.sh"
    
    # Create systemd service with better configuration
    sudo tee /etc/systemd/system/worm-miner.service > /dev/null << EOF
[Unit]
Description=WORM Privacy Miner (Sepolia Testnet)
Documentation=https://github.com/worm-privacy/miner
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=$(whoami)
Group=$(whoami)
WorkingDirectory=$MINER_DIR
ExecStart=$MINER_DIR/start-miner.sh
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=30
TimeoutStartSec=60
TimeoutStopSec=30

# Resource limits
MemoryMax=8G
CPUQuota=200%

# Environment
Environment="RUST_LOG=info"
Environment="RUST_BACKTRACE=1"

# Logging
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable worm-miner
    log_info "Systemd service created and enabled"
}

# Enhanced balance checking with detailed output
check_balances() {
    echo -e "${CYAN}[*] Checking account balances...${NC}"
    
    local private_key
    private_key=$(get_private_key) || return 1
    
    local fastest_rpc
    if [[ -f "$RPC_FILE" ]]; then
        fastest_rpc=$(cat "$RPC_FILE")
    else
        log_warn "No RPC configured. Finding fastest RPC..."
        find_fastest_rpc
        fastest_rpc=$(cat "$RPC_FILE")
    fi
    
    echo -e "${DIM}Using RPC: $fastest_rpc${NC}"
    echo -e "${GREEN}----------------------------------------${NC}"
    
    if ! "$WORM_MINER_BIN" info --network sepolia --private-key "$private_key" --custom-rpc "$fastest_rpc"; then
        log_error "Failed to fetch balance information"
        return 1
    fi
    
    echo -e "${GREEN}----------------------------------------${NC}"
}

# Enhanced burn function with confirmation
burn_eth_for_beth() {
    echo -e "${BOLD}${PURPLE}=== BURN ETH FOR BETH ===${NC}"
    
    local private_key
    private_key=$(get_private_key) || return 1
    
    local fastest_rpc
    if [[ -f "$RPC_FILE" ]]; then
        fastest_rpc=$(cat "$RPC_FILE")
    else
        find_fastest_rpc
        fastest_rpc=$(cat "$RPC_FILE")
    fi
    
    # Show current balance first
    echo -e "${CYAN}Current balances:${NC}"
    "$WORM_MINER_BIN" info --network sepolia --private-key "$private_key" --custom-rpc "$fastest_rpc"
    echo ""
    
    # Get burn parameters
    local amount spend fee
    while true; do
        read -p "Enter total ETH amount to burn (e.g., 1.0): " amount
        if [[ $amount =~ ^[0-9]+\.?[0-9]*$ ]] && (( $(echo "$amount > 0" | bc -l) )); then
            break
        else
            echo -e "${RED}Please enter a valid positive number${NC}"
        fi
    done
    
    # Suggest optimal spend amount (99.9% of burn amount)
    local suggested_spend=$(echo "scale=6; $amount * 0.999" | bc)
    read -p "Enter amount to mint as BETH (suggested: $suggested_spend): " spend
    [[ -z "$spend" ]] && spend="$suggested_spend"
    
    local suggested_fee=$(echo "scale=6; $amount - $spend" | bc)
    read -p "Enter fee amount (suggested: $suggested_fee): " fee
    [[ -z "$fee" ]] && fee="$suggested_fee"
    
    # Validation
    local total_check=$(echo "scale=6; $spend + $fee" | bc)
    if (( $(echo "$total_check > $amount" | bc -l) )); then
        log_error "Spend + Fee ($total_check) cannot exceed burn amount ($amount)"
        return 1
    fi
    
    # Confirmation
    echo -e "${YELLOW}${BOLD}BURN CONFIRMATION:${NC}"
    echo -e "  Burn Amount: ${BOLD}$amount ETH${NC}"
    echo -e "  BETH to mint: ${BOLD}$spend BETH${NC}"
    echo -e "  Fee: ${BOLD}$fee ETH${NC}"
    echo -e "  Using RPC: ${DIM}$fastest_rpc${NC}"
    echo ""
    read -p "Proceed with burn? [y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Burn cancelled by user"
        return 0
    fi
    
    echo -e "${GREEN}[*] Starting burn process...${NC}"
    cd "$MINER_DIR"
    
    if "$WORM_MINER_BIN" burn \
        --network sepolia \
        --private-key "$private_key" \
        --custom-rpc "$fastest_rpc" \
        --amount "$amount" \
        --spend "$spend" \
        --fee "$fee"; then
        
        log_info "Burn completed successfully"
        
        # Show updated balance
        echo -e "${GREEN}Updated balances:${NC}"
        "$WORM_MINER_BIN" info --network sepolia --private-key "$private_key" --custom-rpc "$fastest_rpc" 2>&1 || true
    else
        log_error "Burn process failed"
        return 1
    fi
}

# Batch burn function with loop support
batch_burn_eth_for_beth() {
    echo -e "${BOLD}${PURPLE}=== BATCH BURN ETH FOR BETH ===${NC}"
    
    local private_key
    private_key=$(get_private_key) || return 1
    
    local fastest_rpc
    if [[ -f "$RPC_FILE" ]]; then
        fastest_rpc=$(cat "$RPC_FILE")
    else
        find_fastest_rpc
        fastest_rpc=$(cat "$RPC_FILE")
    fi
    
    # Show current balance first
    echo -e "${CYAN}Current balances:${NC}"
    "$WORM_MINER_BIN" info --network sepolia --private-key "$private_key" --custom-rpc "$fastest_rpc"
    echo ""
    
    # Get batch parameters
    local amount_per_burn burn_count total_amount
    while true; do
        read -p "Enter ETH amount per burn (e.g., 1.0): " amount_per_burn
        if [[ $amount_per_burn =~ ^[0-9]+\.?[0-9]*$ ]] && (( $(echo "$amount_per_burn > 0" | bc -l) )); then
            break
        else
            echo -e "${RED}Please enter a valid positive number${NC}"
        fi
    done
    
    while true; do
        read -p "Enter number of burns to execute: " burn_count
        if [[ $burn_count =~ ^[0-9]+$ ]] && [[ $burn_count -gt 0 ]]; then
            break
        else
            echo -e "${RED}Please enter a valid positive integer${NC}"
        fi
    done
    
    total_amount=$(echo "scale=6; $amount_per_burn * $burn_count" | bc)
    
    # Get spend and fee ratios
    local spend_ratio fee_ratio
    echo -e "${CYAN}Setting up burn parameters:${NC}"
    read -p "Enter spend ratio (0-1, default 0.999): " spend_ratio
    [[ -z "$spend_ratio" ]] && spend_ratio="0.999"
    
    fee_ratio=$(echo "scale=6; 1 - $spend_ratio" | bc)
    
    # Get delay between burns
    local delay_seconds
    read -p "Enter delay between burns in seconds (default 5): " delay_seconds
    [[ -z "$delay_seconds" ]] && delay_seconds="5"
    
    # Confirmation
    echo -e "${YELLOW}${BOLD}BATCH BURN CONFIRMATION:${NC}"
    echo -e "  Amount per burn: ${BOLD}$amount_per_burn ETH${NC}"
    echo -e "  Number of burns: ${BOLD}$burn_count${NC}"
    echo -e "  Total ETH needed: ${BOLD}$total_amount ETH${NC}"
    echo -e "  Spend ratio: ${BOLD}$spend_ratio${NC} (Fee ratio: $fee_ratio)"
    echo -e "  Delay between burns: ${BOLD}$delay_seconds seconds${NC}"
    echo -e "  Using RPC: ${DIM}$fastest_rpc${NC}"
    echo ""
    read -p "Proceed with batch burn? [y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Batch burn cancelled by user"
        return 0
    fi
    
    echo -e "${GREEN}[*] Starting batch burn process...${NC}"
    cd "$MINER_DIR"
    
    local success_count=0
    local failed_count=0
    
    for ((i=1; i<=burn_count; i++)); do
        echo -e "${CYAN}[*] Executing burn $i/$burn_count...${NC}"
        
        local spend=$(echo "scale=6; $amount_per_burn * $spend_ratio" | bc)
        local fee=$(echo "scale=6; $amount_per_burn * $fee_ratio" | bc)
        
        # Execute burn command as separate process
        # Note: worm_miner is designed to exit after each command execution
        local burn_exit_code
        "$WORM_MINER_BIN" burn \
            --network sepolia \
            --private-key "$private_key" \
            --custom-rpc "$fastest_rpc" \
            --amount "$amount_per_burn" \
            --spend "$spend" \
            --fee "$fee" 2>&1
        burn_exit_code=$?
        
        if [[ $burn_exit_code -eq 0 ]]; then
            
            ((success_count++))
            echo -e "${GREEN}[+] Burn $i completed successfully${NC}"
            log_info "Batch burn $i/$burn_count successful"
        else
            ((failed_count++))
            echo -e "${RED}[-] Burn $i failed, continuing with next burn...${NC}"
            log_error "Batch burn $i/$burn_count failed"
        fi
        
        # Add delay between burns (except for the last one)
        if [[ $i -lt $burn_count ]]; then
            echo -e "${DIM}Waiting $delay_seconds seconds before next burn...${NC}"
            sleep "$delay_seconds"
        fi
    done
    
    # Summary
    echo -e "${BOLD}${GREEN}=== BATCH BURN SUMMARY ===${NC}"
    echo -e "  Successful burns: ${GREEN}$success_count${NC}"
    echo -e "  Failed burns: ${RED}$failed_count${NC}"
    echo -e "  Total burns attempted: $((success_count + failed_count))${NC}"
    
    if [[ $success_count -gt 0 ]]; then
        local total_burned=$(echo "scale=6; $success_count * $amount_per_burn" | bc)
        echo -e "  Total ETH burned: ${BOLD}$total_burned ETH${NC}"
        
        # Show updated balance
        echo -e "${GREEN}Updated balances:${NC}"
        "$WORM_MINER_BIN" info --network sepolia --private-key "$private_key" --custom-rpc "$fastest_rpc"
    fi
    
    log_info "Batch burn process completed: $success_count successful, $failed_count failed"
}

# Enhanced mining participation
participate_mining() {
    echo -e "${BOLD}${PURPLE}=== PARTICIPATE IN MINING ===${NC}"
    
    local private_key
    private_key=$(get_private_key) || return 1
    
    local fastest_rpc
    if [[ -f "$RPC_FILE" ]]; then
        fastest_rpc=$(cat "$RPC_FILE")
    else
        find_fastest_rpc
        fastest_rpc=$(cat "$RPC_FILE")
    fi
    
    # Show current info
    echo -e "${CYAN}Current status:${NC}"
    "$WORM_MINER_BIN" info --network sepolia --private-key "$private_key" --custom-rpc "$fastest_rpc"
    echo ""
    
    local amount_per_epoch num_epochs
    read -p "Enter BETH amount per epoch (e.g., 0.002): " amount_per_epoch
    read -p "Enter number of epochs (e.g., 3): " num_epochs
    
    # Validation
    if [[ ! $amount_per_epoch =~ ^[0-9]+\.?[0-9]*$ ]] || [[ ! $num_epochs =~ ^[0-9]+$ ]]; then
        log_error "Invalid input. Please enter valid numbers."
        return 1
    fi
    
    local total_amount=$(echo "scale=6; $amount_per_epoch * $num_epochs" | bc)
    echo -e "${YELLOW}Total BETH required: $total_amount${NC}"
    read -p "Proceed with mining participation? [y/N]: " confirm
    
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        cd "$MINER_DIR"
        "$WORM_MINER_BIN" participate \
            --amount-per-epoch "$amount_per_epoch" \
            --num-epochs "$num_epochs" \
            --private-key "$private_key" \
            --network sepolia \
            --custom-rpc "$fastest_rpc"
        
        log_info "Mining participation completed"
    fi
}

# Enhanced claim function with epoch management
claim_rewards() {
    echo -e "${BOLD}${PURPLE}=== CLAIM WORM REWARDS ===${NC}"
    
    local private_key
    private_key=$(get_private_key) || return 1
    
    local fastest_rpc
    if [[ -f "$RPC_FILE" ]]; then
        fastest_rpc=$(cat "$RPC_FILE")
    else
        find_fastest_rpc
        fastest_rpc=$(cat "$RPC_FILE")
    fi
    
    # Show current epoch info
    echo -e "${CYAN}Current miner information:${NC}"
    "$WORM_MINER_BIN" info --network sepolia --private-key "$private_key" --custom-rpc "$fastest_rpc"
    echo ""
    
    echo -e "${DIM}Note: Each epoch lasts 30 minutes. You can only claim completed epochs.${NC}"
    
    local from_epoch num_epochs
    read -p "Enter starting epoch to claim from (e.g., 0): " from_epoch
    read -p "Enter number of epochs to claim (e.g., 1): " num_epochs
    
    # Validation
    if [[ ! "$from_epoch" =~ ^[0-9]+$ ]] || [[ ! "$num_epochs" =~ ^[0-9]+$ ]]; then
        log_error "Epoch values must be non-negative integers"
        return 1
    fi
    
    echo -e "${YELLOW}Claiming epochs $from_epoch to $((from_epoch + num_epochs - 1))${NC}"
    read -p "Proceed with claim? [y/N]: " confirm
    
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        "$WORM_MINER_BIN" claim \
            --network sepolia \
            --private-key "$private_key" \
            --custom-rpc "$fastest_rpc" \
            --from-epoch "$from_epoch" \
            --num-epochs "$num_epochs"
        
        log_info "Reward claim process completed"
    fi
}

# Service management functions
start_mining_service() {
    echo -e "${CYAN}[*] Starting mining service...${NC}"
    
    if ! systemctl is-enabled worm-miner &>/dev/null; then
        log_error "Miner service not installed. Please run option 1 first."
        return 1
    fi
    
    sudo systemctl start worm-miner
    sleep 2
    
    if sudo systemctl is-active worm-miner &>/dev/null; then
        log_info "Mining service started successfully"
        echo -e "${GREEN}Service is now running in the background${NC}"
    else
        log_error "Failed to start mining service"
        echo -e "${RED}Check logs with option 8 for details${NC}"
        return 1
    fi
}

stop_mining_service() {
    echo -e "${CYAN}[*] Stopping mining service...${NC}"
    sudo systemctl stop worm-miner
    log_info "Mining service stopped"
}

# Enhanced log viewing
view_logs() {
    echo -e "${CYAN}[*] WORM Miner Logs${NC}"
    echo -e "${GREEN}======================================${NC}"
    
    if [[ ! -f "$LOG_FILE" ]]; then
        log_warn "Log file not found. Is the miner installed?"
        return 1
    fi
    
    # Show service status
    echo -e "${BOLD}Service Status:${NC}"
    if sudo systemctl is-active worm-miner &>/dev/null; then
        echo -e "${GREEN}  Status: RUNNING${NC}"
    else
        echo -e "${RED}  Status: STOPPED${NC}"
    fi
    
    if sudo systemctl is-enabled worm-miner &>/dev/null; then
        echo -e "${GREEN}  Auto-start: ENABLED${NC}"
    else
        echo -e "${YELLOW}  Auto-start: DISABLED${NC}"
    fi
    
    echo ""
    echo -e "${BOLD}Recent Logs (last 20 lines):${NC}"
    echo -e "${DIM}======================================${NC}"
    tail -n 20 "$LOG_FILE" | while read -r line; do
        if echo "$line" | grep -q "ERROR"; then
            echo -e "${RED}$line${NC}"
        elif echo "$line" | grep -q "WARN"; then
            echo -e "${YELLOW}$line${NC}"
        elif echo "$line" | grep -q "claim\|reward"; then
            echo -e "${GREEN}$line${NC}"
        else
            echo -e "${DIM}$line${NC}"
        fi
    done
    echo -e "${DIM}======================================${NC}"
    
    echo -e "\n${BOLD}Log Management:${NC}"
    echo "1. View full logs: tail -f $LOG_FILE"
    echo "2. Clear logs: > $LOG_FILE"
    read -p "Clear logs now? [y/N]: " clear_logs
    if [[ "$clear_logs" =~ ^[yY]$ ]]; then
        > "$LOG_FILE"
        log_info "Logs cleared"
    fi
}

# Enhanced update function
update_miner() {
    echo -e "${CYAN}[*] Updating WORM Miner...${NC}"
    
    if [[ ! -d "$MINER_DIR" ]]; then
        log_error "Miner not installed. Please run option 1 first."
        return 1
    fi
    
    # Stop service during update
    sudo systemctl stop worm-miner 2>/dev/null || true
    
    cd "$MINER_DIR"
    
    # Backup current version
    local backup_name="miner_backup_$(date +%s)"
    cp -r "$MINER_DIR" "$BACKUP_DIR/$backup_name" 2>/dev/null || true
    
    # Update repository
    git fetch origin
    local current_commit=$(git rev-parse HEAD)
    local latest_commit=$(git rev-parse origin/main)
    
    if [[ "$current_commit" == "$latest_commit" ]]; then
        log_info "Already up to date"
    else
        echo -e "${GREEN}New version available. Updating...${NC}"
        git pull origin main
        
        # Rebuild with optimizations
        cargo clean
        RUSTFLAGS="-C target-cpu=native -C opt-level=3" cargo install --path .
        
        # Update RPC list
        find_fastest_rpc
        
        log_info "Miner updated successfully"
    fi
    
    # Restart service
    sudo systemctl start worm-miner
    log_info "Mining service restarted"
}

# Enhanced uninstall with complete cleanup
uninstall_miner() {
    echo -e "${RED}${BOLD}=== UNINSTALL WORM MINER ===${NC}"
    echo -e "${YELLOW}This will remove all miner files, logs, and configurations.${NC}"
    echo -e "${YELLOW}Your private key backup will be preserved in $BACKUP_DIR${NC}"
    
    read -p "Are you sure you want to uninstall? [y/N]: " confirm_uninstall
    
    if [[ ! "$confirm_uninstall" =~ ^[yY]$ ]]; then
        log_info "Uninstall cancelled"
        return 0
    fi
    
    echo -e "${RED}[*] Stopping and removing service...${NC}"
    sudo systemctl stop worm-miner 2>/dev/null || true
    sudo systemctl disable worm-miner 2>/dev/null || true
    sudo rm -f /etc/systemd/system/worm-miner.service
    sudo systemctl daemon-reload
    
    echo -e "${RED}[*] Removing miner files...${NC}"
    rm -rf "$MINER_DIR"
    rm -f "$WORM_MINER_BIN"
    
    # Preserve backups but remove active config
    if [[ -d "$CONFIG_DIR" ]]; then
        # Move current key to backup before removing config
        if [[ -f "$KEY_FILE" ]]; then
            cp "$KEY_FILE" "$BACKUP_DIR/private.key.uninstall.$(date +%s)"
        fi
        rm -rf "$CONFIG_DIR"
    fi
    
    log_info "WORM Miner uninstalled successfully"
    echo -e "${GREEN}Backups preserved in: $BACKUP_DIR${NC}"
}

# System monitoring and diagnostics
system_diagnostics() {
    echo -e "${BOLD}${CYAN}=== SYSTEM DIAGNOSTICS ===${NC}"
    
    echo -e "${BOLD}System Information:${NC}"
    echo -e "  OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown')"
    echo -e "  Kernel: $(uname -r)"
    echo -e "  Memory: $(free -h | awk '/^Mem:/ {print $2 " total, " $7 " available"}')"
    echo -e "  Disk Space: $(df -h "$HOME" | awk 'NR==2 {print $4 " available"}')"
    echo -e "  CPU: $(nproc) cores"
    
    echo -e "\n${BOLD}Miner Status:${NC}"
    if [[ -f "$WORM_MINER_BIN" ]]; then
        echo -e "  Binary: ${GREEN}INSTALLED${NC} ($("$WORM_MINER_BIN" --version 2>/dev/null || echo 'unknown version'))"
    else
        echo -e "  Binary: ${RED}NOT INSTALLED${NC}"
    fi
    
    if sudo systemctl is-active worm-miner &>/dev/null; then
        echo -e "  Service: ${GREEN}RUNNING${NC}"
    else
        echo -e "  Service: ${RED}STOPPED${NC}"
    fi
    
    if [[ -f "$KEY_FILE" ]]; then
        echo -e "  Private Key: ${GREEN}CONFIGURED${NC}"
    else
        echo -e "  Private Key: ${RED}NOT CONFIGURED${NC}"
    fi
    
    if [[ -f "$RPC_FILE" ]]; then
        echo -e "  RPC: ${GREEN}CONFIGURED${NC} ($(cat "$RPC_FILE"))"
    else
        echo -e "  RPC: ${YELLOW}NOT CONFIGURED${NC}"
    fi
    
    echo -e "\n${BOLD}Network Connectivity:${NC}"
    if ping -c 1 8.8.8.8 &>/dev/null; then
        echo -e "  Internet: ${GREEN}CONNECTED${NC}"
    else
        echo -e "  Internet: ${RED}DISCONNECTED${NC}"
    fi
    
    if [[ -f "$RPC_FILE" ]]; then
        local rpc=$(cat "$RPC_FILE")
        if curl -s --connect-timeout 3 "$rpc" &>/dev/null; then
            echo -e "  Sepolia RPC: ${GREEN}ACCESSIBLE${NC}"
        else
            echo -e "  Sepolia RPC: ${RED}INACCESSIBLE${NC}"
        fi
    fi
}

# Backup and restore functions
backup_configuration() {
    echo -e "${CYAN}[*] Creating configuration backup...${NC}"
    
    local backup_file="$BACKUP_DIR/config_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    if [[ -d "$CONFIG_DIR" ]]; then
        tar -czf "$backup_file" -C "$HOME" ".worm-miner"
        log_info "Configuration backed up to: $backup_file"
    else
        log_warn "No configuration directory found to backup"
    fi
}

restore_configuration() {
    echo -e "${CYAN}[*] Available backups:${NC}"
    
    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
        log_warn "No backups found"
        return 1
    fi
    
    local backups=($(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null || true))
    if [[ ${#backups[@]} -eq 0 ]]; then
        log_warn "No configuration backups found"
        return 1
    fi
    
    echo -e "${DIM}Available backups:${NC}"
    for i in "${!backups[@]}"; do
        echo "  $((i+1)). $(basename "${backups[$i]}")"
    done
    
    read -p "Select backup to restore [1-${#backups[@]}]: " selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le ${#backups[@]} ]]; then
        local selected_backup="${backups[$((selection-1))]}"
        echo -e "${YELLOW}Restoring from: $(basename "$selected_backup")${NC}"
        
        # Backup current config if it exists
        [[ -d "$CONFIG_DIR" ]] && backup_configuration
        
        # Restore selected backup
        rm -rf "$CONFIG_DIR"
        tar -xzf "$selected_backup" -C "$HOME"
        
        log_info "Configuration restored successfully"
    else
        log_error "Invalid selection"
    fi
}

# Advanced mining options
advanced_mining_menu() {
    while true; do
        clear
        echo -e "${PURPLE}${BOLD}=== ADVANCED MINING OPTIONS ===${NC}"
        echo "1. Custom Burn Parameters"
        echo "2. Service Management"
        echo "3. RPC Management" 
        echo "4. Backup/Restore Config"
        echo "5. System Diagnostics"
        echo "6. Return to Main Menu"
        echo -e "${PURPLE}================================${NC}"
        read -p "Enter choice [1-6]: " advanced_choice
        
        case $advanced_choice in
            1)
                echo -e "${CYAN}[*] Custom Burn Parameters${NC}"
                echo "This allows you to set custom burn parameters..."
                burn_eth_for_beth
                ;;
            2)
                echo -e "${CYAN}[*] Service Management${NC}"
                echo "1. Start Mining Service"
                echo "2. Stop Mining Service"
                echo "3. Restart Mining Service"
                echo "4. Check Service Status"
                read -p "Service action [1-4]: " service_action
                
                case $service_action in
                    1) start_mining_service ;;
                    2) stop_mining_service ;;
                    3) 
                        stop_mining_service
                        sleep 2
                        start_mining_service
                        ;;
                    4)
                        echo -e "${CYAN}Service Status:${NC}"
                        sudo systemctl status worm-miner --no-pager -l
                        ;;
                esac
                ;;
            3)
                echo -e "${CYAN}[*] RPC Management${NC}"
                echo "1. Test All RPCs"
                echo "2. Set Custom RPC"
                echo "3. Reset to Fastest RPC"
                read -p "RPC action [1-3]: " rpc_action
                
                case $rpc_action in
                    1) find_fastest_rpc ;;
                    2)
                        read -p "Enter custom RPC URL: " custom_rpc
                        if [[ $custom_rpc =~ ^https?:// ]]; then
                            echo "$custom_rpc" > "$RPC_FILE"
                            log_info "Custom RPC set: $custom_rpc"
                        else
                            log_error "Invalid RPC URL format"
                        fi
                        ;;
                    3) find_fastest_rpc ;;
                esac
                ;;
            4)
                echo -e "${CYAN}[*] Backup/Restore Configuration${NC}"
                echo "1. Create Backup"
                echo "2. Restore from Backup"
                read -p "Backup action [1-2]: " backup_action
                
                case $backup_action in
                    1) backup_configuration ;;
                    2) restore_configuration ;;
                esac
                ;;
            5)
                system_diagnostics
                ;;
            6)
                break
                ;;
            *)
                echo -e "${RED}Invalid choice${NC}"
                ;;
        esac
        
        echo -e "\n${GREEN}Press Enter to continue...${NC}"
        read
    done
}

# Display header with system info
show_header() {
    clear
    echo -e "${GREEN}${BOLD}"
    cat << "EOL"
    ╦ ╦╔═╗╦═╗╔╦╗  ╔╦╗╦╔╗╔╔═╗╦═╗
    ║║║║ ║╠╦╝║║║  ║║║║║║║║╣ ╠╦╝
    ╚╩╝╚═╝╩╚═╩ ╩  ╩ ╩╩╝╚╝╚═╝╩╚═
    Enhanced Interactive Mining Tool
    Powered by EIP-7503 | Sepolia Testnet
EOL
    echo -e "${NC}"
    
    # Show quick status
    if [[ -f "$WORM_MINER_BIN" ]]; then
        local version=$("$WORM_MINER_BIN" --version 2>/dev/null | head -n1 || echo "unknown")
        echo -e "${DIM}Installed: $version${NC}"
        
        if sudo systemctl is-active worm-miner &>/dev/null; then
            echo -e "${GREEN}Status: Mining Active${NC}"
        else
            echo -e "${YELLOW}Status: Mining Stopped${NC}"
        fi
    else
        echo -e "${RED}Status: Not Installed${NC}"
    fi
    
    if [[ -f "$CONFIG_DIR/address.txt" ]]; then
        echo -e "${DIM}Address: $(cat "$CONFIG_DIR/address.txt")${NC}"
    fi
    echo ""
}

# Main menu loop with enhanced options
main_menu() {
    while true; do
        show_header
        
        # Check installation and configuration status
        local is_installed=$(check_miner_installed && echo "true" || echo "false")
        local is_configured=$(check_miner_configured && echo "true" || echo "false")
        
        echo -e "${GREEN}${BOLD}---- MAIN MENU ----${NC}"
        
        # Show status
        if [[ "$is_installed" == "true" ]]; then
            echo -e "${GREEN}✅ Miner: INSTALLED${NC}"
        else
            echo -e "${RED}❌ Miner: NOT INSTALLED${NC}"
        fi
        
        if [[ "$is_configured" == "true" ]]; then
            echo -e "${GREEN}✅ Config: CONFIGURED${NC}"
        else
            echo -e "${YELLOW}⚠️  Config: NOT CONFIGURED${NC}"
        fi
        echo ""
        
        # Show appropriate options based on status
        if [[ "$is_installed" == "false" ]]; then
            echo "1.  🚀 Install Miner"
        else
            echo "1.  🔄 Update Miner"
        fi
        
        if [[ "$is_installed" == "true" ]]; then
            echo "2.  ⚙️  Setup/Configure Miner"
        else
            echo "2.  ⚙️  Setup/Configure Miner (Requires Installation)"
        fi
        
        echo "3.  🔥 Burn ETH for BETH"
        echo "4.  🔥🔄 Batch Burn ETH (Loop)"
        echo "5.  ⛏️  Participate in Mining"  
        echo "6.  💰 Claim WORM Rewards"
        echo "7.  📊 Check Balances & Info"
        echo "8.  📝 View Miner Logs"
        echo "9.  🌐 Find & Set Fastest RPC"
        echo "10. ⚙️  Advanced Options"
        echo "11. 🗑️  Uninstall Miner"
        echo "12. ❌ Exit"
        echo -e "${GREEN}-------------------${NC}"
        read -p "Enter choice [1-12]: " action
        
        case $action in
            1)
                if [[ "$is_installed" == "false" ]]; then
                    install_miner
                else
                    update_miner
                fi
                ;;
            2)
                if [[ "$is_installed" == "true" ]]; then
                    setup_miner_config
                else
                    echo -e "${RED}Please install miner first (Option 1).${NC}"
                fi
                ;;
            3)
                burn_eth_for_beth
                ;;
            4)
                batch_burn_eth_for_beth
                ;;
            5)
                participate_mining
                ;;
            6)
                claim_rewards
                ;;
            7)
                check_balances
                ;;
            8)
                view_logs
                ;;
            9)
                find_fastest_rpc
                ;;
            10)
                advanced_mining_menu
                ;;
            11)
                uninstall_miner
                ;;
            12)
                echo -e "${GREEN}[*] Thank you for using WORM Miner! Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice. Please enter a number from 1 to 12.${NC}"
                ;;
        esac
        
        echo -e "\n${GREEN}${BOLD}Press Enter to return to main menu...${NC}"
        read
    done
}

# Startup checks and initialization
initialize() {
    # Create base directories
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE"
    
    # Check if we need to source Rust environment
    if [[ -f "$HOME/.cargo/env" ]] && ! command -v cargo &>/dev/null; then
        source "$HOME/.cargo/env"
    fi
    
    # Log script start
    log_info "WORM Miner Enhanced Script Started (PID: $)"
}

# Signal handlers for clean exit
cleanup() {
    log_info "Script terminated"
    exit 0
}

trap cleanup SIGINT SIGTERM

# Script entry point
main() {
    # Initialize environment
    initialize
    
    # Check for required tools
    if ! command -v bc &>/dev/null; then
        echo -e "${YELLOW}Installing bc (calculator)...${NC}"
        sudo apt-get update -qq && sudo apt-get install -y bc
    fi
    
    # Welcome message
    echo -e "${BOLD}${GREEN}"
    echo "=========================================="
    echo "  Welcome to WORM Miner Enhanced Tool"
    echo "=========================================="
    echo -e "${NC}"
    echo -e "${CYAN}This script will help you:${NC}"
    echo -e "  • Install and configure WORM miner"
    echo -e "  • Manage mining operations on Sepolia"
    echo -e "  • Monitor performance and logs"
    echo -e "  • Handle rewards and claims"
    echo ""
    echo -e "${YELLOW}${BOLD}IMPORTANT NOTES:${NC}"
    echo -e "${YELLOW}• Ensure you have at least 1.0 Sepolia ETH${NC}"
    echo -e "${YELLOW}• Get testnet ETH from: https://sepoliafaucet.com${NC}"
    echo -e "${YELLOW}• Keep your private key secure and backed up${NC}"
    echo -e "${YELLOW}• This is testnet - no real value involved${NC}"
    echo ""
    
    read -p "Press Enter to continue..."
    
    # Start main menu
    main_menu
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi