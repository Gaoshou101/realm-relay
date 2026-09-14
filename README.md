# Realm Relay Manager (多落地支持 & 多级菜单版)

轻量、高性能、零内存负担的 Realm TCP 端口中转管理脚本。专为优化线路 VPS 中转至一个或多个落地节点（VLESS + REALITY、SOCKS5、直连服务等）打造。

---

## 🌟 特性

- 🚀 **多落地 / 多端口转发**：单机支持同时中转多个不同端口至多台不同的落地服务器。
- 📑 **清晰多级菜单**：主菜单分类清晰，包含“规则管理”、“运维控制”、“日志排错”等独立二级子菜单。
- ⚙️ **完整规则生命周期**：支持随时查看规则列表与监听状态、添加新中转、修改指定规则、按序号删除规则。
- 🛡️ **安全与环境隔离**：自动识别 `x86_64` 与 `aarch64`，musl 静态二进制部署；自动配置 systemd 守护自启与防火墙（UFW / firewalld）端口放行。
- ⌨️ **全局快捷指令**：安装后在任何终端输入 `realm.sh` 即可随时呼出交互菜单，也支持命令行参数快捷调用。

---

## 🚀 一键安装与使用

在需要做中转的 Linux VPS 上执行以下命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Gaoshou101/realm-relay/main/realm.sh)
```

> **备用命令（若未安装 curl）：**
> ```bash
> wget -qO- https://raw.githubusercontent.com/Gaoshou101/realm-relay/main/realm.sh | bash
> ```

---

## 📋 菜单结构预览

### 主菜单 (`realm.sh`)
```text
=================================================
        Realm 高性能 TCP 端口中转管理脚本        
        项目: https://github.com/Gaoshou101/realm-relay  
=================================================
  1. 运行状态概览
  2. 转发规则管理 (查看 / 添加 / 修改 / 删除)
  3. 服务运维控制 (启动 / 停止 / 重启 / 自启)
  4. 日志与排错 (实时追踪 / 历史日志)
  5. 安装 / 重装 Realm
  6. 彻底卸载 Realm
  0. 退出脚本
=================================================
服务状态: [运行中]   当前生效规则数: 2 条
=================================================
```

### 转发规则管理子菜单
```text
---------------- 转发规则管理 ----------------
  1. 查看所有规则与监听状态
  2. 添加新的中转规则 (支持多落地)
  3. 修改已有中转规则
  4. 删除指定中转规则
  0. 返回主菜单
----------------------------------------------
```

---

## ⚡ 命令行快捷调用

除了交互菜单，也支持直接通过参数执行：

| 命令 | 说明 |
| :--- | :--- |
| `realm.sh status` | 查看整体状态与当前所有中转规则 |
| `realm.sh list` | 列出所有中转转发规则明细 |
| `realm.sh add` | 快速添加一条新转发规则 |
| `realm.sh del` | 交互式选择删除某条转发规则 |
| `realm.sh logs` | 查看实时转发日志 (`journalctl -f`) |
| `realm.sh restart` | 快速重启 Realm 服务 |
| `realm.sh stop` | 停止 Realm 服务 |
| `realm.sh start` | 启动 Realm 服务 |
| `realm.sh uninstall` | 卸载 Realm 并清除配置文件 |

---

## 📂 文件与服务路径

- 核心二进制：`/usr/local/bin/realm`
- 配置文件：`/etc/realm/config.toml`
- systemd 服务：`/etc/systemd/system/realm.service`
- 管理脚本路径：`/usr/local/bin/realm.sh`（快捷命令：`realm-cli`）
