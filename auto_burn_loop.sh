#!/bin/bash
set -e
set -o pipefail

# 不再导入外部脚本，直接在本脚本中实现所需功能

# 使用说明：
# 1. 正常运行: ./auto_burn_loop.sh
# 2. 调试模式: ./auto_burn_loop.sh --debug
# 3. 手动确认模式: ./auto_burn_loop.sh --manual
# 4. 查看帮助: ./auto_burn_loop.sh --help
# 5. 自定义参数: ./auto_burn_loop.sh --count 5 --amount 0.5 --delay 5

# 配置路径
CONFIG_DIR="$HOME/.worm_miner"
MINER_DIR="$HOME/miner"
LOG_FILE="$CONFIG_DIR/miner.log"
KEY_FILE="$CONFIG_DIR/private.key"
RPC_FILE="$CONFIG_DIR/fastest_rpc.log"
BACKUP_DIR="$CONFIG_DIR/backups"

# 尝试多个可能的worm-miner路径
if [[ -f "$HOME/.cargo/bin/worm-miner" ]]; then
    WORM_MINER_BIN="$HOME/.cargo/bin/worm-miner"
elif [[ -f "$CONFIG_DIR/worm-miner" ]]; then
    WORM_MINER_BIN="$CONFIG_DIR/worm-miner"
elif [[ -f "$MINER_DIR/worm-miner" ]]; then
    WORM_MINER_BIN="$MINER_DIR/worm-miner"
elif [[ -f "$MINER_DIR/target/release/worm-miner" ]]; then
    WORM_MINER_BIN="$MINER_DIR/target/release/worm-miner"
else
    # 如果找不到，使用默认路径，后续会检查
    WORM_MINER_BIN="$HOME/.cargo/bin/worm-miner"
fi

# Enhanced Sepolia RPC list
SEPOLIA_RPCS=(
    "https://sepolia.drpc.org"
    "https://ethereum-sepolia-rpc.publicnode.com" 
    "https://eth-sepolia.public.blastapi.io"
    "https://rpc.sepolia.org"
    "https://sepolia.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161"
    "https://sepolia.gateway.tenderly.co"
)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# 配置
BURN_COUNT=10
BURN_AMOUNT="1"
SPEND_AMOUNT="0.999"
FEE_AMOUNT="0.001"
DELAY_SECONDS=3
AUTO_CONFIRM=true  # 设置为true自动确认所有提示，false则需要手动确认
DEBUG=true  # 设置为true输出调试信息

# 日志函数
log_info() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1${NC}" | tee -a "$LOG_FILE" 2>/dev/null || true
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1${NC}" | tee -a "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" | tee -a "$LOG_FILE" 2>/dev/null || true
}

# 获取私钥函数
get_private_key() {
    if [[ ! -f "$KEY_FILE" ]]; then
        log_error "私钥文件未找到。请先安装矿工程序。"
        return 1
    fi
    
    local private_key
    private_key=$(cat "$KEY_FILE")
    if [[ ! $private_key =~ ^0x[0-9a-fA-F]{64}$ ]]; then
        log_error "私钥格式无效: $KEY_FILE"
        return 1
    fi
    echo "$private_key"
}

# 查找最快RPC函数
find_fastest_rpc() {
    echo -e "${CYAN}[*] 测试Sepolia RPCs以找到最快的节点...${NC}"
    
    local fastest_rpc=""
    local min_latency=999999
    local temp_dir="/tmp/rpc_test_$$"
    mkdir -p "$temp_dir"
    
    # 并行测试RPC以获得更快的结果
    for i in "${!SEPOLIA_RPCS[@]}"; do
        local rpc="${SEPOLIA_RPCS[$i]}"
        (
            # 使用简单的JSON-RPC调用进行测试
            local start_time=$(date +%s%N)
            response=$(curl -s --connect-timeout 3 --max-time 8 \
                -X POST -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
                "$rpc" 2>/dev/null || echo "ERROR")
            local end_time=$(date +%s%N)
            
            if [[ "$response" != "ERROR" ]] && echo "$response" | grep -q "result"; then
                local latency=$(echo "scale=3; ($end_time - $start_time) / 1000000000" | bc)
                echo "$latency:$rpc" > "$temp_dir/result_$i"
                echo -e "  ${DIM}测试 $rpc: ${YELLOW}${latency}s${NC}"
            else
                echo "999999:$rpc" > "$temp_dir/result_$i"
                echo -e "  ${DIM}测试 $rpc: ${RED}失败${NC}"
            fi
        ) &
    done
    
    # 等待所有后台任务
    wait
    
    # 找到最快的RPC
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
        log_info "已选择最快的RPC: $fastest_rpc (${min_latency}s 延迟)"
    else
        log_error "无法找到可用的RPC。请检查您的网络连接。"
        return 1
    fi
}

# 检查worm-miner程序是否存在
check_worm_miner() {
    if [[ ! -f "$WORM_MINER_BIN" ]]; then
        log_error "错误: 未找到 worm-miner 程序: $WORM_MINER_BIN"
        echo -e "${RED}请确保已正确安装 worm-miner 程序，可能的位置:${NC}"
        echo -e "  - $HOME/.cargo/bin/worm-miner"
        echo -e "  - $CONFIG_DIR/worm-miner"
        echo -e "  - $MINER_DIR/worm-miner"
        echo -e "  - $MINER_DIR/target/release/worm-miner"
        return 1
    fi
    return 0
}

# 处理命令行参数
if [[ $# -gt 0 ]]; then
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${YELLOW}[DEBUG] 接收到命令行参数: $@${NC}"
    fi
    
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --count|-c)
                BURN_COUNT="$2"
                shift 2
                ;;
            --amount|-a)
                BURN_AMOUNT="$2"
                shift 2
                ;;
            --spend|-s)
                SPEND_AMOUNT="$2"
                shift 2
                ;;
            --fee|-f)
                FEE_AMOUNT="$2"
                shift 2
                ;;
            --delay|-d)
                DELAY_SECONDS="$2"
                shift 2
                ;;
            --manual)
                AUTO_CONFIRM=false
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --help|-h)
                echo -e "${BOLD}使用方法:${NC}"
                echo -e "  $0 [选项]"
                echo -e "\n${BOLD}选项:${NC}"
                echo -e "  --count, -c NUMBER    设置燃烧次数 (默认: $BURN_COUNT)"
                echo -e "  --amount, -a NUMBER   设置每次燃烧金额 (默认: $BURN_AMOUNT ETH)"
                echo -e "  --spend, -s NUMBER    设置spend金额 (默认: $SPEND_AMOUNT ETH)"
                echo -e "  --fee, -f NUMBER      设置fee金额 (默认: $FEE_AMOUNT ETH)"
                echo -e "  --delay, -d SECONDS   设置燃烧间隔时间 (默认: $DELAY_SECONDS 秒)"
                echo -e "  --manual              启用手动确认模式"
                echo -e "  --debug               启用调试模式"
                echo -e "  --help, -h            显示此帮助信息"
                exit 0
                ;;
            *)
                echo -e "${RED}未知参数: $1${NC}"
                echo -e "使用 $0 --help 查看帮助信息"
                exit 1
                ;;
        esac
    done
fi

# 检查配置目录
if [[ ! -d "$CONFIG_DIR" ]]; then
    mkdir -p "$CONFIG_DIR"
    log_info "创建配置目录: $CONFIG_DIR"
fi

# 检查worm-miner程序
if [[ "$DEBUG" == "true" ]]; then
    echo -e "${YELLOW}[DEBUG] 检查worm-miner程序: $WORM_MINER_BIN${NC}"
    echo -e "${YELLOW}[DEBUG] 当前工作目录: $(pwd)${NC}"
    echo -e "${YELLOW}[DEBUG] 脚本路径: $0${NC}"
    echo -e "${YELLOW}[DEBUG] 配置目录: $CONFIG_DIR${NC}"
    echo -e "${YELLOW}[DEBUG] 私钥文件: $KEY_FILE${NC}"
    echo -e "${YELLOW}[DEBUG] RPC文件: $RPC_FILE${NC}"
    ls -la "$WORM_MINER_BIN" 2>/dev/null || echo -e "${YELLOW}[DEBUG] worm-miner程序不存在${NC}"
fi

check_worm_miner || exit 1

echo -e "${BOLD}${PURPLE}=== 自动循环燃烧脚本 ===${NC}"
echo -e "${CYAN}配置信息:${NC}"
echo -e "  燃烧次数: ${BOLD}$BURN_COUNT${NC}"
echo -e "  每次燃烧: ${BOLD}$BURN_AMOUNT ETH${NC}"
echo -e "  Spend: ${BOLD}$SPEND_AMOUNT ETH${NC}"
echo -e "  Fee: ${BOLD}$FEE_AMOUNT ETH${NC}"
echo -e "  间隔时间: ${BOLD}$DELAY_SECONDS 秒${NC}"
echo -e "  使用程序: ${DIM}$WORM_MINER_BIN${NC}"
echo -e "  自动确认: ${BOLD}$(if [[ "$AUTO_CONFIRM" == "true" ]]; then echo "是"; else echo "否"; fi)${NC}"
echo -e "  调试模式: ${BOLD}$(if [[ "$DEBUG" == "true" ]]; then echo "开启"; else echo "关闭"; fi)${NC}"
echo ""

# 获取私钥
if [[ "$DEBUG" == "true" ]]; then
    echo -e "${YELLOW}[DEBUG] 尝试获取私钥${NC}"
    if [[ -f "$KEY_FILE" ]]; then
        echo -e "${YELLOW}[DEBUG] 私钥文件存在: $KEY_FILE${NC}"
        echo -e "${YELLOW}[DEBUG] 私钥文件内容前10个字符: $(head -c 10 "$KEY_FILE" 2>/dev/null || echo "无法读取")...${NC}"
    else
        echo -e "${YELLOW}[DEBUG] 私钥文件不存在: $KEY_FILE${NC}"
    fi
fi

private_key=$(get_private_key)
if [[ $? -ne 0 ]]; then
    echo -e "${YELLOW}未找到私钥文件或私钥格式无效。${NC}"
    
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${YELLOW}[DEBUG] get_private_key函数返回错误${NC}"
    fi
    
    if [[ "$AUTO_CONFIRM" != "true" ]]; then
        echo -e "${CYAN}请手动输入您的私钥 (格式: 0x开头的64位十六进制字符):${NC}"
        read -p "> " input_private_key
        
        # 验证私钥格式
        if [[ ! $input_private_key =~ ^0x[0-9a-fA-F]{64}$ ]]; then
            log_error "输入的私钥格式无效"
            if [[ "$DEBUG" == "true" ]]; then
                echo -e "${YELLOW}[DEBUG] 输入的私钥: ${input_private_key:0:6}...${NC}"
            fi
            exit 1
        fi
        
        private_key=$input_private_key
        
        # 询问是否保存私钥
        read -p "是否保存私钥到配置文件? [y/N]: " save_key
        if [[ "$save_key" =~ ^[yY]$ ]]; then
            echo "$private_key" > "$KEY_FILE"
            chmod 600 "$KEY_FILE" 2>/dev/null || true
            log_info "私钥已保存到: $KEY_FILE"
        fi
    else
        log_error "自动模式下需要预先配置私钥文件"
        exit 1
    fi
else
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${YELLOW}[DEBUG] 成功获取私钥: ${private_key:0:6}...${NC}"
    fi
fi

# 获取最快的RPC
if [[ "$DEBUG" == "true" ]]; then
    echo -e "${YELLOW}[DEBUG] 尝试获取最快RPC${NC}"
    if [[ -f "$RPC_FILE" ]]; then
        echo -e "${YELLOW}[DEBUG] RPC缓存文件存在: $RPC_FILE${NC}"
        echo -e "${YELLOW}[DEBUG] RPC缓存文件内容: $(cat "$RPC_FILE" 2>/dev/null || echo "无法读取")${NC}"
    else
        echo -e "${YELLOW}[DEBUG] RPC缓存文件不存在: $RPC_FILE${NC}"
    fi
fi

if [[ -f "$RPC_FILE" ]]; then
    fastest_rpc=$(cat "$RPC_FILE")
    echo -e "${CYAN}使用缓存的RPC: ${DIM}$fastest_rpc${NC}"
    
    # 询问是否重新测试RPC
    retest_rpc="n"
    if [[ "$AUTO_CONFIRM" != "true" ]]; then
        read -p "是否重新测试RPC以获取最快节点? [y/N]: " retest_rpc
    fi
    
    if [[ "$retest_rpc" =~ ^[yY]$ ]]; then
        if [[ "$DEBUG" == "true" ]]; then
            echo -e "${YELLOW}[DEBUG] 开始测试RPC节点${NC}"
        fi
        
        find_fastest_rpc || {
            if [[ "$DEBUG" == "true" ]]; then
                echo -e "${YELLOW}[DEBUG] RPC测试失败${NC}"
            fi
            
            if [[ "$AUTO_CONFIRM" != "true" ]]; then
                echo -e "${YELLOW}RPC测试失败，请手动输入RPC地址:${NC}"
                read -p "> " input_rpc
                fastest_rpc=$input_rpc
                echo "$fastest_rpc" > "$RPC_FILE"
            else
                log_error "自动模式下RPC测试失败，使用默认RPC"
                fastest_rpc="https://sepolia.drpc.org"
                echo "$fastest_rpc" > "$RPC_FILE"
            fi
        }
    fi
else
    echo -e "${CYAN}正在测试RPC以获取最快节点...${NC}"
    
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${YELLOW}[DEBUG] 开始测试RPC节点${NC}"
    fi
    
    find_fastest_rpc || {
        if [[ "$DEBUG" == "true" ]]; then
            echo -e "${YELLOW}[DEBUG] RPC测试失败${NC}"
        fi
        
        if [[ "$AUTO_CONFIRM" != "true" ]]; then
            echo -e "${YELLOW}RPC测试失败，请手动输入RPC地址:${NC}"
            read -p "> " input_rpc
            fastest_rpc=$input_rpc
        else
            log_error "自动模式下RPC测试失败，使用默认RPC"
            fastest_rpc="https://sepolia.drpc.org"
        fi
        echo "$fastest_rpc" > "$RPC_FILE"
    }
    fastest_rpc=$(cat "$RPC_FILE")
fi

if [[ "$DEBUG" == "true" ]]; then
    echo -e "${YELLOW}[DEBUG] 最终使用的RPC: $fastest_rpc${NC}"
fi

echo ""
echo -e "${YELLOW}${BOLD}确认信息:${NC}"
echo -e "  将执行 ${BOLD}$BURN_COUNT${NC} 次燃烧操作"
echo -e "  总共需要 ${BOLD}$(echo "scale=3; $BURN_COUNT * $BURN_AMOUNT" | bc) ETH${NC}"
echo -e "  使用RPC: ${DIM}$fastest_rpc${NC}"
echo ""
# 如果是自动模式，则自动确认
if [[ "$AUTO_CONFIRM" == "true" ]]; then
    confirm="y"
    echo -e "${GREEN}自动模式：已自动确认燃烧操作${NC}"
else
    echo -e "${RED}${BOLD}请输入 'y' 确认开始燃烧，或按其他键取消${NC}"
    read -p "确认开始自动燃烧? [y/N]: " confirm
    
    # 默认为不确认
    if [[ -z "$confirm" ]]; then
        confirm="n"
    fi
fi

if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo -e "${YELLOW}操作已取消${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}[*] 开始自动燃烧流程...${NC}"
echo ""

# 显示初始余额
echo -e "${CYAN}当前余额:${NC}"
"$WORM_MINER_BIN" info --network sepolia --private-key "$private_key" --custom-rpc "$fastest_rpc" 2>/dev/null || true
echo ""

# 执行燃烧循环
success_count=0
failed_count=0

for ((i=1; i<=BURN_COUNT; i++)); do
    echo -e "${CYAN}[*] 执行第 $i/$BURN_COUNT 次燃烧...${NC}"
    
    # 执行燃烧命令
    # 不再切换目录，直接使用完整路径执行命令
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${YELLOW}[DEBUG] 执行燃烧命令:${NC}"
        echo -e "${YELLOW}[DEBUG] $WORM_MINER_BIN burn --network sepolia --private-key [隐藏] --custom-rpc $fastest_rpc --amount $BURN_AMOUNT --spend $SPEND_AMOUNT --fee $FEE_AMOUNT${NC}"
    fi
    
    if "$WORM_MINER_BIN" burn \
        --network sepolia \
        --private-key "$private_key" \
        --custom-rpc "$fastest_rpc" \
        --amount "$BURN_AMOUNT" \
        --spend "$SPEND_AMOUNT" \
        --fee "$FEE_AMOUNT"; then
        
        ((success_count++))
        echo -e "${GREEN}[+] 第 $i 次燃烧成功完成${NC}"
    else
        ((failed_count++))
        echo -e "${RED}[-] 第 $i 次燃烧失败${NC}"
    fi
    
    # 添加延迟（除了最后一次）
    if [[ $i -lt $BURN_COUNT ]]; then
        echo -e "${DIM}等待 $DELAY_SECONDS 秒后继续...${NC}"
        sleep "$DELAY_SECONDS"
        echo ""
    fi
done

echo ""
echo -e "${BOLD}${GREEN}=== 燃烧完成统计 ===${NC}"
echo -e "  成功燃烧: ${GREEN}$success_count${NC}"
echo -e "  失败燃烧: ${RED}$failed_count${NC}"
echo -e "  总计尝试: $((success_count + failed_count))${NC}"

if [[ $success_count -gt 0 ]]; then
    total_burned=$(echo "scale=6; $success_count * $BURN_AMOUNT" | bc)
    echo -e "  总燃烧量: ${BOLD}$total_burned ETH${NC}"
    
    echo ""
    echo -e "${GREEN}更新后的余额:${NC}"
    "$WORM_MINER_BIN" info --network sepolia --private-key "$private_key" --custom-rpc "$fastest_rpc" 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}自动燃烧流程完成！${NC}"