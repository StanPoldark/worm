# WORM 挖矿完整中文教程

## 📋 目录
1. [项目介绍](#项目介绍)
2. [系统要求](#系统要求)
3. [前期准备](#前期准备)
4. [安装教程](#安装教程)
5. [挖矿操作](#挖矿操作)
6. [常见问题](#常见问题)
7. [安全提示](#安全提示)

---

## 🎯 项目介绍

**WORM (Privacy Mining)** 是基于 **EIP-7503** 标准的隐私挖矿项目，通过零知识证明技术实现：

- **🔥 燃烧挖矿**：将 ETH 燃烧为 BETH 代币
- **🛡️ 隐私保护**：使用 ZK-SNARK 零知识证明
- **💰 奖励机制**：每个周期（30分钟）可获得 50 WORM 代币奖励
- **🧪 测试网络**：当前在 Sepolia 测试网运行

---

## 💻 系统要求

### 硬件要求
- **内存**：至少 16GB RAM（推荐 32GB）
- **存储**：至少 20GB 可用空间
- **CPU**：4核心及以上（支持 x86_64）
- **网络**：稳定的互联网连接

### 软件要求
- **操作系统**：Ubuntu 20.04+ / Debian 11+ （推荐）
- **权限**：sudo 权限用于安装依赖
- **用户**：建议使用普通用户（非 root）

---

## 🎫 前期准备

### 1. 获取 Sepolia 测试网 ETH

**重要**：你需要至少 **1.0 Sepolia ETH** 来开始挖矿。

#### 获取方式：
1. **官方水龙头**：https://sepoliafaucet.com
2. **备用水龙头**：
   - https://sepolia-faucet.pk910.de
   - https://www.alchemy.com/faucets/ethereum-sepolia

#### 操作步骤：
```bash
# 如果还没有钱包，可以用这个命令生成
openssl rand -hex 32 | sed 's/^/0x/'
```

### 2. 准备以太坊钱包
- 确保你有一个以太坊私钥（64位十六进制，以0x开头）
- **⚠️ 警告**：虽然是测试网，也要妥善保管私钥
- 建议专门为测试创建新钱包

---

## 🛠️ 安装教程

### 方法一：使用一键脚本（推荐）

```bash
# 1. 下载脚本
wget -O worm-miner.sh https://raw.githubusercontent.com/StanPoldark/worm/refs/heads/main/worm_miner.sh
chmod +x worm-miner.sh

# 2. 运行脚本
./worm-miner.sh

# 3. 选择选项 1 进行完整安装
```

### 方法二：手动安装

#### 步骤 1：安装系统依赖
```bash
# 更新系统
sudo apt update && sudo apt upgrade -y

# 安装必需依赖
sudo apt install -y \
  build-essential cmake libgmp-dev libsodium-dev \
  nasm curl m4 git wget unzip bc \
  nlohmann-json3-dev pkg-config libssl-dev \
  python3 python3-pip jq
```

#### 步骤 2：安装 Rust 工具链
```bash
# 安装 Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# 激活环境
source $HOME/.cargo/env

# 验证安装
rustc --version
cargo --version
```

#### 步骤 3：克隆挖矿仓库
```bash
# 进入用户目录
cd ~

# 删除旧安装（如果存在）
rm -rf miner proof-of-burn

# 克隆官方仓库
git clone https://github.com/worm-privacy/miner
cd miner

# 验证仓库
git remote -v
```

#### 步骤 4：下载参数文件
```bash
# 下载 ZK-SNARK 参数（约8GB，需要耐心等待）
make download_params

# 验证下载
ls -la | grep zkey
```

#### 步骤 5：编译安装挖矿程序
```bash
# 优化编译安装
RUSTFLAGS="-C target-cpu=native -C opt-level=3" cargo install --path .

# 验证安装
worm-miner --version
```

#### 步骤 6：配置私钥
```bash
# 创建配置目录
mkdir -p ~/.worm-miner

# 安全输入私钥（不会显示在屏幕上）
read -sp "请输入你的私钥: " PRIVATE_KEY
echo ""

# 保存私钥
echo "$PRIVATE_KEY" > ~/.worm-miner/private.key
chmod 600 ~/.worm-miner/private.key

# 清理历史记录
history -c
```

---

## ⛏️ 挖矿操作

### 1. 检查余额
```bash
# 查看当前 ETH 和 BETH 余额
worm-miner info --network sepolia --private-key $(cat ~/.worm-miner/private.key)
```

**输出示例**：
```
Current epoch: 156
ETH balance: 1.500000000000000000
BETH balance: 0.000000000000000000
WORM balance: 0.000000000000000000
```

### 2. 燃烧 ETH 获得 BETH

**BETH** 是参与挖矿的必需代币，通过燃烧 ETH 获得。

```bash
# 燃烧 1 ETH，获得 0.999 BETH（0.001 作为手续费）
worm-miner burn \
  --network sepolia \
  --private-key $(cat ~/.worm-miner/private.key) \
  --amount 1 \
  --spend 0.999 \
  --fee 0.001
```

**参数说明**：
- `--amount`：总燃烧 ETH 数量
- `--spend`：转换为 BETH 的数量
- `--fee`：网络手续费

### 3. 参与挖矿
```bash
# 为接下来 3 个周期，每个周期投入 0.002 BETH
worm-miner participate \
  --amount-per-epoch 0.002 \
  --num-epochs 3 \
  --private-key $(cat ~/.worm-miner/private.key) \
  --network sepolia
```

**参数说明**：
- `--amount-per-epoch`：每个周期投入的 BETH 数量
- `--num-epochs`：参与的周期数量
- 每个周期持续 **30分钟**

### 4. 自动挖矿（推荐）
```bash
# 启动自动挖矿服务
worm-miner mine \
  --network sepolia \
  --private-key $(cat ~/.worm-miner/private.key) \
  --amount-per-epoch "0.0001" \
  --num-epochs "3" \
  --claim-interval "10"
```

### 5. 领取奖励
```bash
# 领取从第7个周期开始的1个周期奖励
worm-miner claim \
  --from-epoch 7 \
  --network sepolia \
  --num-epochs 1 \
  --private-key $(cat ~/.worm-miner/private.key)
```

**注意**：
- 只能领取已完成的周期奖励
- 查看当前周期：`worm-miner info`
- 如果当前是第8周期，可以尝试领取第7周期的奖励

---

## 🚀 一键脚本使用指南

### 主菜单功能

1. **🚀 安装挖矿程序**
   - 自动检查系统要求
   - 安装所有依赖和 Rust
   - 下载参数文件
   - 配置私钥和 RPC
   - 创建系统服务

2. **🔥 燃烧 ETH**
   - 交互式燃烧参数设置
   - 自动计算最优费率
   - 实时余额显示

3. **⛏️ 参与挖矿**
   - 设置每周期投入量
   - 选择参与周期数
   - 自动验证 BETH 余额

4. **💰 领取奖励**
   - 查看可领取周期
   - 批量领取奖励
   - 更新余额显示

5. **📊 查看余额**
   - ETH、BETH、WORM 余额
   - 当前周期信息
   - 挖矿状态

6. **📝 查看日志**
   - 彩色编码日志输出
   - 实时服务状态
   - 错误诊断信息

7. **🔄 更新程序**
   - 自动检查新版本
   - 安全更新流程
   - 保留配置信息

8. **🌐 RPC 管理**
   - 自动测试多个 RPC
   - 选择最快节点
   - 延迟监控

### 高级选项菜单

9. **⚙️ 高级选项**
   - 服务管理（启动/停止/重启）
   - 自定义 RPC 设置
   - 配置备份/恢复
   - 系统诊断

---

## 💡 挖矿策略建议

### 初学者策略
```bash
# 1. 先燃烧少量 ETH 测试
燃烧：0.1 ETH → 0.099 BETH

# 2. 小额参与挖矿
每周期：0.001 BETH
周期数：2-3 个

# 3. 熟悉流程后增加投入
```

### 进阶策略
```bash
# 1. 批量燃烧
燃烧：1-2 ETH → 获得更多 BETH

# 2. 长期挖矿
每周期：0.01-0.05 BETH
周期数：10-20 个

# 3. 定期领取奖励优化资金利用率
```

---

## ❓ 常见问题

### Q1: 余额显示为 0 怎么办？
```bash
# 检查交易状态
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_getTransactionReceipt","params":["你的交易哈希"],"id":1}' \
  https://rpc.sepolia.org

# 重新检查余额
worm-miner info --network sepolia --private-key $(cat ~/.worm-miner/private.key)
```

### Q2: 参数文件下载失败
```bash
# 检查网络连接
ping github.com

# 重新下载
cd ~/miner
make download_params

# 手动下载（如果自动下载失败）
wget https://github.com/worm-privacy/miner/releases/download/v0.1.0/params.tar.gz
tar -xzf params.tar.gz
```

### Q3: 编译失败
```bash
# 清理并重新编译
cargo clean
RUSTFLAGS="-C target-cpu=native" cargo install --path .

# 如果还是失败，检查依赖
sudo apt install -y build-essential cmake libgmp-dev
```

### Q4: 服务启动失败
```bash
# 检查服务状态
sudo systemctl status worm-miner

# 查看详细日志
journalctl -u worm-miner -f

# 手动启动调试
cd ~/miner
./start-miner.sh
```

### Q5: RPC 连接问题
```bash
# 测试 RPC 连接
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  https://sepolia.drpc.org

# 使用脚本自动找最快 RPC
./worm-miner.sh
# 选择选项 8
```

---

## 🔒 安全提示

### 私钥安全
- ✅ **使用测试网专用私钥**，不要用主网钱包
- ✅ **定期备份**私钥文件到安全位置
- ✅ **设置文件权限**：`chmod 600 ~/.worm-miner/private.key`
- ❌ **永远不要**在公共场所输入私钥
- ❌ **永远不要**将私钥发送给任何人

### 系统安全
```bash
# 1. 创建专用用户（可选）
sudo useradd -m -s /bin/bash worm-miner
sudo su - worm-miner

# 2. 设置防火墙
sudo ufw enable
sudo ufw allow ssh

# 3. 定期更新系统
sudo apt update && sudo apt upgrade -y
```

### 备份策略
```bash
# 自动备份脚本
#!/bin/bash
BACKUP_DIR="$HOME/worm-backups/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

# 备份配置
cp -r ~/.worm-miner "$BACKUP_DIR/"

# 备份日志
cp ~/miner/*.log "$BACKUP_DIR/" 2>/dev/null || true

echo "备份完成: $BACKUP_DIR"
```

---

## 📈 监控和优化

### 性能监控
```bash
# 查看 CPU 和内存使用
htop

# 监控挖矿进程
ps aux | grep worm-miner

# 查看网络连接
netstat -tlnp | grep worm-miner
```

### 日志分析
```bash
# 实时查看日志
tail -f ~/.worm-miner/miner.log

# 过滤错误日志
grep "ERROR" ~/.worm-miner/miner.log

# 查看奖励相关日志
grep "claim\|reward" ~/.worm-miner/miner.log
```

### 优化建议
1. **RPC 优化**：定期测试并切换到最快的 RPC
2. **资源优化**：根据系统性能调整挖矿参数
3. **网络优化**：使用稳定的网络连接
4. **时间优化**：在网络较空闲时进行大额操作

---

## 🔧 高级配置

### 自定义 RPC 设置
```bash
# 添加自定义 RPC
echo "https://your-custom-rpc.com" > ~/.worm-miner/fastest_rpc.log

# 测试 RPC 延迟
for rpc in "https://sepolia.drpc.org" "https://rpc.sepolia.org"; do
  echo "Testing $rpc"
  time curl -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$rpc"
done
```

### 服务管理
```bash
# 启动挖矿服务
sudo systemctl start worm-miner

# 停止挖矿服务  
sudo systemctl stop worm-miner

# 重启挖矿服务
sudo systemctl restart worm-miner

# 查看服务状态
sudo systemctl status worm-miner

# 开机自启
sudo systemctl enable worm-miner

# 禁用自启
sudo systemctl disable worm-miner
```

### 参数调优
```bash
# 低资源模式（较少 BETH 投入）
--amount-per-epoch "0.0001"
--num-epochs "1"

# 高效模式（更多投入，更多奖励）
--amount-per-epoch "0.01"
--num-epochs "5"

# 长期挖矿模式
--amount-per-epoch "0.005"
--num-epochs "10"
--claim-interval "5"  # 每5个周期自动领取
```

---

## 📊 收益计算

### 基础收益模型
- **投入**：每周期的 BETH 数量
- **周期**：30分钟/周期
- **奖励**：WORM 代币（数量依赖于网络参与度）
- **成本**：燃烧的 ETH（测试网无实际成本）

### 示例计算
```
假设参数：
- 燃烧：1 ETH → 0.999 BETH
- 投入：每周期 0.01 BETH
- 可参与：99 个周期
- 预期收益：? WORM（取决于网络奖励池）
```

---

## 🎯 最佳实践

### 新手入门流程
1. **准备阶段**（30分钟）
   - 获取 Sepolia ETH
   - 安装挖矿程序
   - 配置环境

2. **测试阶段**（1小时）
   - 小额燃烧测试
   - 参与1-2个周期
   - 熟悉操作流程

3. **正式挖矿**（持续）
   - 批量燃烧获得 BETH
   - 长期参与挖矿
   - 定期领取奖励

### 风险管理
- 📍 **分批操作**：不要一次性投入所有 ETH
- 📍 **定期备份**：备份私钥和配置文件
- 📍 **监控日志**：及时发现和解决问题
- 📍 **网络安全**：使用安全的网络环境

---

## 🆘 故障排除

### 连接问题
```bash
# 测试网络连接
ping google.com

# 测试 Sepolia RPC
curl https://sepolia.drpc.org

# 重新选择最快 RPC
./worm-miner.sh  # 选择选项 8
```

### 服务问题
```bash
# 查看详细错误
sudo journalctl -u worm-miner --no-pager -l

# 重置服务
sudo systemctl daemon-reload
sudo systemctl restart worm-miner

# 手动启动调试
cd ~/miner
RUST_LOG=debug ./start-miner.sh
```

### 余额同步问题
```bash
# 强制刷新状态
worm-miner info --network sepolia --private-key $(cat ~/.worm-miner/private.key)

# 检查交易确认
# 在 https://sepolia.etherscan.io 查询你的地址
```

---

## 📞 支持和社区

### 官方资源
- **GitHub**：https://github.com/worm-privacy/miner
- **文档**：查看仓库中的 README.md
- **问题报告**：GitHub Issues

### 社区支持
- 加入相关 Telegram 或 Discord 群组
- 关注项目更新和公告
- 参与社区讨论和经验分享

---

## 🎉 总结

WORM 挖矿是一个创新的隐私挖矿项目，通过本教程你可以：

1. ✅ **完整安装**挖矿环境
2. ✅ **安全配置**私钥和RPC
3. ✅ **高效参与**挖矿活动
4. ✅ **稳定获得**WORM 奖励
5. ✅ **及时解决**常见问题

**记住**：这是测试网项目，主要目的是学习和测试新技术。保持谨慎，享受挖矿过程！

---

## 📝 更新日志

- **v1.0**：基础教程发布
- **v1.1**：增加故障排除章节
- **v1.2**：添加高级配置和优化建议
- **v1.3**：完善安全提示和最佳实践

---

*最后更新：2025年9月2日*