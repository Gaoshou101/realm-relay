# Realm Relay Manager (一键安装与中转管理脚本)

轻量、高性能、零配置心智负担的 Realm TCP 端口中转一键部署与管理脚本。专为优化线路中转至落地机（如 VLESS + REALITY、Socks5、直连服务等）场景打造。

---

## 特性

- 🚀 **极速一键部署**：自动识别 `x86_64` 与 `aarch64` 架构，拉取官方 musl 静态二进制包并校验 SHA256。
- ⚙️ **交互自选端口**：安装时自定义中转监听端口、落地机 IP/域名以及落地端口，内置冲突检测与输入校验。
- 🛡️ **安全与调优**：预置 systemd 守护进程、崩溃自启、100 万文件描述符限制与基础防火墙放行规则（UFW / firewalld）。
- 📊 **便捷运维管理**：一键查看服务状态、端口占用、实时日志、修改监听端口、修改落地目标或彻底卸载。
- ⌨️ **全局快捷唤出**：安装后在任意终端直接输入 `realm.sh` 即可唤出交互菜单。

---

## 快速安装与使用

在需要做中转的 Linux VPS 上执行以下命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Gaoshou101/realm-relay/main/realm.sh)
```

> **备用命令（若未安装 curl）：**
> ```bash
> wget -qO- https://raw.githubusercontent.com/Gaoshou101/realm-relay/main/realm.sh | bash
> ```

---

## 交互菜单预览

安装完成后，在终端直接输入 `realm.sh` 即可打开管理菜单：

```text
=================================================
        Realm 高性能 TCP 端口中转管理脚本        
        项目: https://github.com/Gaoshou101/realm-relay  
=================================================
  1. 安装 / 重装 Realm (自选监听与落地端口)
  2. 查看运行状态
  3. 查看实时运行日志 (Ctrl+C 退出)
  4. 查看最近 50 条日志
  5. 修改本机中转监听端口
  6. 修改落地目标地址与端口
  7. 重启 Realm
  8. 停止 Realm
  9. 启动 Realm
  10. 彻底卸载 Realm
  0. 退出
=================================================
```

---

## 命令行快捷调用

支持直接传入参数执行对应功能，适合脚本调用或快捷操作：

| 快捷命令 | 说明 |
| :--- | :--- |
| `realm.sh status` | 查看 Realm 运行状态与端口配置 |
| `realm.sh port` | 修改本机中转监听端口 |
| `realm.sh remote` | 修改落地端目标 IP / 端口 |
| `realm.sh logs` | 查看实时转发日志 |
| `realm.sh log-recent` | 查看最近 50 条日志 |
| `realm.sh restart` | 重启 Realm 服务 |
| `realm.sh stop` | 停止 Realm 服务 |
| `realm.sh start` | 启动 Realm 服务 |
| `realm.sh uninstall` | 卸载 Realm 及所有服务配置 |

---

## 文件与服务路径

- 二进制程序：`/usr/local/bin/realm`
- 配置文件：`/etc/realm/config.toml`
- systemd 服务：`/etc/systemd/system/realm.service`
- 管理脚本路径：`/usr/local/bin/realm.sh`（快捷别名：`realm-cli`）
