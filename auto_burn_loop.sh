#!/bin/bash

# 导入原始脚本中的函数
source "$(dirname "$0")/worm_miner.sh"

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

echo -e "${BOLD}${PURPLE}=== 自动循环燃烧脚本 ===${NC}"
echo -e "${CYAN}配置信息:${NC}"
echo -e "  燃烧次数: ${BOLD}$BURN_COUNT${NC}"
echo -e "  每次燃烧: ${BOLD}$BURN_AMOUNT ETH${NC}"
echo -e "  Spend: ${BOLD}$SPEND_AMOUNT ETH${NC}"
echo -e "  Fee: ${BOLD}$FEE_AMOUNT ETH${NC}"
echo -e "  间隔时间: ${BOLD}$DELAY_SECONDS 秒${NC}"
echo ""

# 获取私钥
private_key=$(get_private_key) || exit 1

# 获取最快的RPC
if [[ -f "$RPC_FILE" ]]; then
    fastest_rpc=$(cat "$RPC_FILE")
else
    find_fastest_rpc
    fastest_rpc=$(cat "$RPC_FILE")
fi

echo ""
echo -e "${YELLOW}${BOLD}确认信息:${NC}"
echo -e "  将执行 ${BOLD}$BURN_COUNT${NC} 次燃烧操作"
echo -e "  总共需要 ${BOLD}$(echo "scale=3; $BURN_COUNT * $BURN_AMOUNT" | bc) ETH${NC}"
echo -e "  使用RPC: ${DIM}$fastest_rpc${NC}"
echo ""
read -p "确认开始自动燃烧? [y/N]: " confirm

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
    cd "$MINER_DIR"
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