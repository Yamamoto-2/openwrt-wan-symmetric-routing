# iStoreOS / OpenWrt 双 WAN 对称回程插件项目说明

## 项目名称（暂定）

- 工作名：`luci-app-wan-vrf`
- 目标：在 iStoreOS / OpenWrt 上实现“**高速上网出口** + **公网服务出口**”的双 WAN 分工，并解决端口转发回包走错出口的问题。

---

## 一、背景与问题定义

当前目标网络中存在两个 WAN：

1. **10G WAN**
   - 主要用途：给内网设备提供高速上网
   - 特点：带宽高，但不承担公网入站服务的主入口

2. **1G PPPoE WAN**
   - 主要用途：承载公网 IP、端口转发、网站托管、远程访问
   - 特点：有公网入口能力，但带宽较小

### 现有问题

当 OpenWrt 以 10G WAN 作为默认出口时：

- 公网用户从 1G PPPoE 进入
- 端口转发能到达内网服务器
- 但服务器回包可能从 10G WAN 出去
- 导致出现 **非对称路由（asymmetric routing）**
- 最终表现为：
  - TCP 建连失败
  - 端口转发看起来“进得来、回不去”
  - 外部访问网站、SSH、游戏服等不稳定或直接失败

当 OpenWrt 以 1G PPPoE 作为默认出口时：

- 公网服务正常
- 但所有普通上网流量也走 PPPoE
- 内网用户只能跑到 1G
- 无法发挥 10G WAN 的价值

### 用户侧额外要求

- 不希望内网设备手动更改默认网关
- 不希望“有公网需求的机器”单独改路由
- 希望路由器自身统一处理
- 希望最终可做成 iStoreOS 可安装插件，尽量图形化

---

## 二、核心目标

实现以下效果：

### 目标 1：普通上网默认走 10G WAN

- LAN 客户端默认通过 10G WAN 上网
- 不影响下载、视频、普通网页访问的高速能力

### 目标 2：从 PPPoE 入站的连接，回包必须仍走 PPPoE

- 任何来自 1G PPPoE 公网 IP 的入站连接
- 只要被 DNAT / 端口转发到内网服务器
- 其回包必须从同一个 PPPoE 接口返回
- 不能错误地走 10G WAN

### 目标 3：尽可能兼容 iStoreOS 当前老 firewall / 老策略路由环境

- 考虑 iStoreOS 上存在旧版 firewall、旧版策略路由插件生态
- 插件不能强依赖新版 nft-only 方案
- 初版尽量以 shell + iproute2 + hotplug 为主

### 目标 4：为后续扩展预留空间

后续可扩展：

- 指定 LAN 主机永远走 PPPoE
- 指定端口 / 服务绑定到某个 WAN
- 多个公网 WAN 的入站对称回程
- 基于 VRF / fwmark 的混合模式
- 与 mwan3 / policy-based-routing 共存

---

## 三、为什么考虑 VRF

Linux 内核本身支持 VRF（Virtual Routing and Forwarding）。

你当前系统的“全局网络选项”里已经出现了：

- `tcp_l3mdev_accept`
- `udp_l3mdev_accept`

这说明：

- 当前内核大概率已经启用了 VRF 相关功能
- 只是 OpenWrt / iStoreOS 默认没有把它作为常规功能暴露出来
- 可以尝试利用 VRF 做“逻辑上的双路由域分离”

### VRF 的理论优势

相比单纯的旧式策略路由，VRF 有这些优点：

1. **逻辑更清晰**
   - `vrf-fast` 负责 10G 出口
   - `vrf-public` 负责 PPPoE 公网入口与回程

2. **路由表隔离**
   - 每个 VRF 对应独立 table
   - 容易理解、调试

3. **更适合插件化**
   - 可以抽象成：
     - 接口绑定到哪个 VRF
     - 哪类流量进入哪个 VRF
     - 哪些转发需要对称回程

4. **长期更有扩展性**
   - 以后加第 3 个 WAN、专线、WireGuard、ZeroTier 都更方便

### 但要注意

OpenWrt / iStoreOS 不是标准 Debian/Ubuntu 服务器环境，因此 VRF 方案要先验证：

- 内核模块是否实际可用
- `ip link add vrf-xxx type vrf table N` 是否可执行
- PPPoE 接口能否顺利挂入 VRF
- firewall / NAT / DNAT / conntrack 与 VRF 的交互是否符合预期
- LuCI 网络配置是否会覆盖掉 VRF 手工设置

因此：**VRF 很值得作为主方向研究，但第一版不要把希望全部压在 VRF 上。**

---

## 四、建议的技术路线：分两阶段推进

---

## 阶段 A：先做“可用版”

目标：

- 不管内部实现优雅不优雅
- 先在 iStoreOS 上把需求跑通
- 证明这个插件方向成立

### 阶段 A 推荐方案

采用：

- `iptables` / `fwmark` / `connmark`
- `ip rule`
- `ip route table`
- `hotplug` 自动重建规则
- LuCI 提供简化配置页面

### 原理

对于从 PPPoE 进入的连接：

1. 在进入时打连接标记
2. 在回包时恢复这个连接标记
3. 用 `ip rule` 根据 mark 把流量送到 PPPoE 专属路由表
4. 这样即使系统默认出口是 10G，入站服务的回包仍会强制走 PPPoE

### 这样做的优点

- 与老版 OpenWrt / iStoreOS 兼容性更高
- 更容易先做出 MVP
- 比 VRF 少很多未知坑
- 适合第一次开发 OpenWrt 插件

### 这样做的缺点

- 逻辑没 VRF 那么优雅
- 日后扩展复杂度更高
- 和某些已有策略路由插件可能冲突
- 调试时需要看 mark、conntrack、rule、route，多层排查

---

## 阶段 B：再做“VRF 增强版”

等阶段 A 验证成功后，再新增 VRF 模式：

- 支持创建 `vrf-fast`、`vrf-public`
- 支持把指定 WAN 接口绑定到 VRF
- 支持针对入站服务流量采用 VRF 隔离回程
- 把现有基于 mark 的方案抽象成后备模式

### 为什么这样分阶段

因为第一次做 OpenWrt 插件时，最大的风险不是功能做不全，而是：

- LuCI 不熟
- UCI 不熟
- procd / init 不熟
- hotplug 生命周期不熟
- firewall reload 时规则丢失
- WAN 重拨时规则失效

先做 fwmark MVP，能更快进入“能跑、能调试、能发包”的状态。

---

## 五、插件定位

建议插件定义为：

### 插件一句话描述

> 为 iStoreOS / OpenWrt 提供“双 WAN 对称回程”能力，让高速上网与公网服务共存。

### 适用场景

- 10G / 2.5G / DHCP WAN 用于普通上网
- PPPoE / 公网 IP WAN 用于端口转发和网站托管
- 家庭实验室 / Homelab
- 软路由挂服务器
- 旁路环境下不想改客户端网关
- 需要公网访问但又不想牺牲高速出口

---

## 六、第一版功能范围（MVP）

只做最刚需的功能。

### 1. 基础接口选择

用户在 LuCI 页面中指定：

- **高速默认出口 WAN**
- **公网入站 WAN**
- **LAN 区域 / 内网网段**
- 是否启用“对称回程”

### 2. 自动创建策略

插件自动生成：

- 入站 WAN 连接打标规则
- 对应 `ip rule`
- 对应 `route table`
- WAN 重拨后的自动恢复机制

### 3. 状态展示

LuCI 页面显示：

- 当前高速 WAN 接口
- 当前公网 WAN 接口
- PPPoE 是否在线
- 默认路由当前是否为高速 WAN
- 对称回程规则是否已加载

### 4. 调试页面

LuCI 中最好加一个“诊断”区块，显示：

- `ip rule`
- `ip route show table xxx`
- 关键 `iptables -t mangle` 规则
- 当前 connmark 命中计数
- 最近一次规则重建时间

---

## 七、建议暂缓到第二版的功能

这些很有价值，但第一版别碰太多：

- VRF 真实隔离模式
- 按 LAN 主机维度绑定出口
- 按端口 / 协议绑定出口
- IPv6 对称回程
- 多公网 WAN 同时托管
- 与 mwan3 深度联动
- DNS 绑定 WAN
- hairpin NAT / NAT loopback 的高级修复
- 可视化流量统计

---

## 八、技术实现建议

---

## 8.1 插件整体结构建议

建议项目目录大致这样组织：

```text
luci-app-wan-vrf/
├── Makefile
├── root/
│   ├── etc/
│   │   ├── config/
│   │   │   └── wan_vrf
│   │   ├── init.d/
│   │   │   └── wan_vrf
│   │   ├── hotplug.d/
│   │   │   ├── iface/
│   │   │   │   └── 95-wan-vrf
│   │   │   └── firewall/
│   │   │       └── 95-wan-vrf
│   │   └── wan-vrf/
│   │       ├── core.sh
│   │       ├── apply.sh
│   │       ├── diagnose.sh
│   │       └── vrf_experiment.sh
│   └── usr/
│       ├── libexec/
│       │   └── wan-vrf-helper
│       └── share/
│           └── rpcd/
│               └── acl.d/
│                   └── luci-app-wan-vrf.json
├── luasrc/
│   ├── controller/
│   │   └── wan_vrf.lua
│   ├── model/cbi/
│   │   └── wan_vrf/
│   │       ├── config.lua
│   │       └── status.lua
│   └── view/
│       └── wan_vrf/
│           └── status.htm
└── README.md
```

> 说明：新旧 LuCI 目录结构在不同版本里会有差异。你本地开发时可以参考目标 iStoreOS 上已安装插件的目录结构来调整。

---

## 8.2 UCI 配置设计

建议新建一个 UCI 配置文件：

```text
/etc/config/wan_vrf
```

建议字段：

```uci
config settings 'main'
    option enabled '1'
    option mode 'fwmark'
    option fast_wan 'wan10g'
    option public_wan 'wan_pppoe'
    option lan_network 'lan'
    option route_table_public '100'
    option fwmark_public '0x100'
    option auto_apply '1'
    option debug '1'
```

后续扩展 VRF 时：

```uci
    option mode 'vrf'
    option vrf_fast_name 'vrf-fast'
    option vrf_public_name 'vrf-public'
    option vrf_fast_table '200'
    option vrf_public_table '100'
```

### 配置项说明

- `enabled`：总开关
- `mode`：`fwmark` 或 `vrf`
- `fast_wan`：高速默认出口
- `public_wan`：公网入站接口
- `lan_network`：LAN 逻辑网络名
- `route_table_public`：公网回程专用路由表
- `fwmark_public`：连接标记
- `debug`：输出调试日志

---

## 8.3 核心脚本职责拆分

### `core.sh`

负责提供公共函数，例如：

- 获取接口实际设备名
- 获取接口 IPv4 地址
- 获取默认网关
- 判断接口是否在线
- 输出日志

### `apply.sh`

负责真正下发规则，例如：

- 刷新 mangle 规则
- 写入 `ip rule`
- 写入 `route table`
- 重建回程策略

### `diagnose.sh`

输出当前状态，供 LuCI 调用：

- 接口信息
- 路由信息
- connmark 规则
- 防火墙命中情况

### `vrf_experiment.sh`

专门做实验性 VRF 功能，不与第一版正式逻辑强耦合。

这样可以避免：

- 主功能一开始就被 VRF 坑住
- 后续你想切换实现方式时，项目结构混乱

---

## 九、第一版推荐实现逻辑（fwmark 模式）

下面给的是逻辑，不是最终成品代码。

### 1. 确认公网 WAN 入口接口

例如配置：

- `public_wan=wan_pppoe`

从 UCI / ubus / network 获取其真实设备，可能是：

- `pppoe-wan`
- 或其他实际运行名

### 2. 建立连接标记规则

当流量从公网 WAN 入口进入时：

- 对该连接设置 connmark

核心思路：

```bash
iptables -t mangle -A PREROUTING -i pppoe-wan -j CONNMARK --set-mark 0x100
iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark
iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark
```

更稳妥的写法一般还会区分：

- 新连接打标
- 已有连接恢复标记
- 只对入站 WAN 命中

### 3. 建立策略路由

```bash
ip rule add fwmark 0x100 table 100
ip route add default dev pppoe-wan table 100
```

必要时加网关：

```bash
ip route add default via <pppoe_gateway> dev pppoe-wan table 100
```

### 4. 保持主路由仍是 10G

系统主表默认路由仍然指向 10G WAN。

这样：

- 普通流量走 10G
- 被打标的连接回包走 PPPoE

### 5. 在接口变动时重建

需要在这些事件触发重建：

- PPPoE 重拨
- WAN 地址变化
- firewall reload
- 系统重启
- 用户点 LuCI 的“保存并应用”

---

## 十、VRF 模式的实验目标

等 fwmark 模式跑通后，再尝试以下实验：

### 实验 1：确认内核支持

测试命令：

```bash
ip link add vrf-public type vrf table 100
ip link show type vrf
```

如果成功，说明基础支持存在。

### 实验 2：绑定 WAN 到 VRF

```bash
ip link set dev pppoe-wan master vrf-public
```

观察：

- 接口是否报错
- PPPoE 会不会断
- 防火墙规则是否仍然生效

### 实验 3：启用 l3mdev accept

检查并设置：

```bash
sysctl -w net.ipv4.tcp_l3mdev_accept=1
sysctl -w net.ipv4.udp_l3mdev_accept=1
```

### 实验 4：验证 DNAT 回程

验证场景：

- 公网访问 PPPoE 的端口映射
- 观察回包是否留在 VRF 内走 PPPoE 出去

### 实验 5：评估 LuCI / firewall 兼容性

主要看：

- firewall restart 后 VRF 绑定是否丢失
- netifd reload 后是否重置 master
- PPPoE 重连后是否需要重新绑定

---

## 十一、LuCI 页面建议

建议先做一个很朴素但可用的页面。

### 页面 1：基础设置

字段：

- 启用插件
- 运行模式：`fwmark` / `vrf(实验)`
- 高速 WAN
- 公网 WAN
- LAN 网络
- 路由表编号
- mark 值
- 调试日志开关

### 页面 2：状态 / 诊断

显示：

- 插件当前状态：已启用 / 未启用
- 实际识别到的 WAN 设备名
- 高速 WAN 在线状态
- 公网 WAN 在线状态
- 当前默认路由
- `ip rule`
- `table 100` 路由内容
- mangle 规则摘要

### 页面 3：一键重载

按钮：

- 重新应用规则
- 刷新诊断
- 导出调试信息

---

## 十二、你用 Codex 本地开发时的建议流程

### 第一步：不要一开始就做完整 LuCI

先在本地把 shell MVP 跑起来：

1. 手工写 `apply.sh`
2. SSH 到 iStoreOS 上执行
3. 验证回程逻辑真的成立
4. 再把它包装成 init/hotplug
5. 最后再上 LuCI

这是最稳的路线。

### 第二步：先做最小调试集

你至少要准备这些命令的观察结果：

```bash
ip addr
ip rule
ip route
ip route show table 100
iptables -t mangle -S
iptables -t nat -S
logread | tail -n 100
```

### 第三步：准备测试场景

推荐准备：

- 一台内网服务器，固定 IP
- 一个 PPPoE 公网映射端口，比如 8080 -> 192.168.1.10:80
- 一个外网测试源，比如手机 4G/5G
- `tcpdump` 分别抓：
  - PPPoE 口
  - 10G WAN 口
  - LAN 口

重点看：

- SYN 从哪进
- SYN/ACK 从哪出
- 回包是否被错误送到 10G

### 第四步：每一步都做“可回滚”

OpenWrt 上一旦路由搞错，可能会把自己锁在外面。

务必：

- 保留串口/本地控制台方案
- 或者保留管理口单独直连
- 每次 apply 前先备份旧规则

---

## 十三、开发优先级建议

### P0：必须先完成

- 纯 shell 版 fwmark 对称回程验证成功
- PPPoE 重拨后规则可恢复
- reboot 后规则可恢复

### P1：第一版发布前完成

- UCI 配置读写
- init.d 服务
- hotplug 自动应用
- LuCI 配置页面
- LuCI 状态页

### P2：增强项

- VRF 实验模式
- 诊断导出
- 规则冲突检测
- 检测 mwan3 / policy-based-routing 是否同时启用

### P3：更长期规划

- 多公网 WAN
- 基于主机/端口的策略
- IPv6
- eBPF / nft 原生实现
- 流量可视化

---

## 十四、主要风险点

### 1. iStoreOS 的 firewall 版本较老

影响：

- 可能仍主要依赖 iptables 兼容层
- 某些新写法不可用
- 不同版本行为可能不同

### 2. PPPoE 接口名与物理设备名不稳定

影响：

- 脚本不能写死接口名
- 必须从 network / ubus 动态取

### 3. firewall restart 可能清空自定义规则

影响：

- 必须有 hotplug / init 重建逻辑
- 最好不要让用户手工加规则

### 4. mwan3 / 其他策略路由插件冲突

影响：

- 可能覆盖 `ip rule`
- 可能修改默认路由优先级
- 第一版要提示“不建议共用”

### 5. VRF 与 OpenWrt 网络栈整合存在未知坑

影响：

- VRF 适合作为第二阶段实验，不适合一开始孤注一掷

---

## 十五、建议的 README 首屏描述

可以直接给仓库先放这样一句：

> `luci-app-wan-vrf` is an iStoreOS/OpenWrt plugin for symmetric return-path routing in dual-WAN environments, allowing a high-speed default WAN for outbound traffic and a public PPPoE WAN for inbound port-forwarded services.

---

## 十六、给 Codex 的首个任务建议

你现在最适合先让 Codex 做的，不是整插件，而是下面这几个任务。

### Task 1：生成项目骨架

让 Codex 先创建：

- `README.md`
- `Makefile`
- `root/etc/config/wan_vrf`
- `root/etc/init.d/wan_vrf`
- `root/etc/wan-vrf/core.sh`
- `root/etc/wan-vrf/apply.sh`
- `root/etc/wan-vrf/diagnose.sh`

### Task 2：实现 shell MVP

目标：

- 从 UCI 读取 `public_wan`、`route_table_public`、`fwmark_public`
- 自动解析实际设备名
- 自动写入 iptables mangle 规则
- 自动写入 `ip rule`
- 自动写入 `ip route show table X`

### Task 3：实现诊断命令

目标：

- 执行 `/etc/wan-vrf/diagnose.sh`
- 打印当前关键状态
- 供你快速粘贴日志排查

### Task 4：最后再接 LuCI

等 shell 逻辑验证后，再让 Codex 帮你补：

- controller
- CBI 配置页
- 状态页

---

## 十七、我对这个项目的建议结论

### 技术上

- 这个需求真实存在，而且非常常见
- 只靠现有老策略路由插件，很难优雅解决
- 值得做成一个独立插件

### 路线选择上

- **短期**：先做 `fwmark + ip rule + hotplug`，更容易成功
- **中期**：把 VRF 作为增强模式
- **长期**：抽象成“多 WAN 对称回程框架”

### 开发方式上

- 先 shell MVP
- 再 UCI
- 再 LuCI
- 最后研究 VRF

---

## 十八、下一步建议

你本地开工时，第一步就做下面两件事：

1. **先验证系统 VRF 能不能创建**
2. **同时写 fwmark MVP，先确保需求能跑通**

因为最怕的是：

- 你一开始就 all in VRF
- 结果被 OpenWrt 的网络管理细节拖住
- 项目迟迟没有第一个可用版本

---

## 十九、附：建议的首轮手工验证清单

在 iStoreOS 上手工跑这些：

```bash
ip link add vrf-public type vrf table 100
ip link show type vrf
sysctl net.ipv4.tcp_l3mdev_accept
sysctl net.ipv4.udp_l3mdev_accept
ubus call network.interface.wan status
ubus call network.interface.wan_pppoe status
iptables -t mangle -S
ip rule
ip route
```

如果 VRF 创建失败，就说明：

- 插件第一版必须走 fwmark

如果 VRF 创建成功，也不要立刻切主路线，只说明：

- 第二阶段很值得做

---

## 二十、仓库初始化建议

推荐仓库名：

- `luci-app-wan-vrf`
- 或更直白一点：`luci-app-symmetric-routing`

我个人更推荐：

- **仓库名**：`luci-app-symmetric-routing`
- **插件 UI 名称**：`WAN Symmetric Routing`

因为这样即使以后底层不是 VRF，也不会名字打架。

---

## 二十一、版本规划建议

### v0.1.0
- shell MVP
- 支持单个公网 WAN 对称回程
- 无 LuCI 或只有简易 LuCI

### v0.2.0
- 完整 LuCI
- 状态页
- hotplug 重建
- 配置持久化

### v0.3.0
- VRF 实验模式
- 冲突检测
- 更好的日志与调试

### v1.0.0
- 在 iStoreOS 上稳定可安装
- 文档完善
- 支持更多用户环境

