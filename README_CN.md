# SCP Action

通过 SSH/SCP 把文件或目录上传到一个或多个远程服务器的 GitHub Action。

基于 Docker 容器实现，自带 `openssh-client` / `sshpass` / GNU `tar`，不依赖 runner 预装的命令行工具，也不需要运行时下载任何二进制。

[English](./README.md)

---

## 功能特性

- 支持**密钥认证**与**密码认证**，私钥支持 passphrase
- 支持**多机并行**传输（逗号分隔）
- 支持 **SSH 跳板机（Proxy / jump host）**
- 支持**主机指纹校验**，防中间人攻击
- 支持 `strip_components`、`overwrite`、`rm`、`tar_dereference`、`!` 排除模式
- 支持 `dry_run` 预演、`debug` 详细日志、`capture_stdout` 输出捕获
- 失败自动回滚远端临时文件
- 兼容老旧服务端（可选 `use_insecure_cipher`）

---

## 快速开始

### 密钥认证（推荐）

```yaml
- name: 上传文件到服务器
  uses: PersiLiao/scp-action@v1
  with:
    host: ${{ secrets.HOST }}
    username: ${{ secrets.USERNAME }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    port: 22
    source: "dist/*"
    target: "/opt/app"
```

### 密码认证

```yaml
- uses: PersiLiao/scp-action@v1
  with:
    host: example.com
    username: foo
    password: ${{ secrets.PASSWORD }}
    source: "tests/a.txt,tests/b.txt"
    target: "/tmp/demo"
```

---

## 传输语义（重要）

本 Action 与 `appleboy/scp-action` / `drone-scp` 保持一致的语义：

1. **本地按 `source` 原样打包**，`source` 中写的路径会完整保留；
2. **在远端解包时才应用 `--strip-components`**。

| source | target | strip_components | 远端结果 |
| --- | --- | --- | --- |
| `tests/a.txt` | `/tmp/out` | `0`（默认） | `/tmp/out/tests/a.txt` |
| `tests/a.txt` | `/tmp/out` | `1` | `/tmp/out/a.txt` |
| `dist/*` | `/opt/app` | `0` | `/opt/app/dist/...` |
| `dist` | `/opt/app` | `1` | `/opt/app/<dist 下的内容>` |

> 即：想「把目录里的内容平铺到目标目录」，用 `source: dist` + `strip_components: 1`。

以 `!` 开头的 `source` 条目会被当作 `tar --exclude` 的排除模式：

```yaml
source: |
  tests/*
  !tests/*.log
```

---

## 参数

### 连接

| 参数 | 说明 | 默认值 | 必填 |
| --- | --- | --- | --- |
| `host` | 远程主机，多台用英文逗号分隔，支持 `host:port` | - | ✓ |
| `port` | SSH 端口 | `22` | |
| `username` | 登录用户名 | - | ✓ |
| `password` | 密码认证（安全性低于密钥） | - | |
| `key` | SSH 私钥全文 | - | |
| `key_path` | SSH 私钥文件路径 | - | |
| `passphrase` | 私钥口令 | - | |
| `fingerprint` | 主机公钥 SHA256 指纹 | - | |
| `protocol` | `tcp` / `tcp4` / `tcp6` | `tcp` | |
| `timeout` | 连接超时 | `30s` | |
| `command_timeout` | 单条远端命令超时 | `10m` | |
| `use_insecure_cipher` | 启用不安全加密算法（兼容老服务端） | `false` | |
| `cipher` | 指定加密算法 | - | |

> `password` 与 `key` / `key_path` 至少提供一个。

### 传输

| 参数 | 说明 | 默认值 | 必填 |
| --- | --- | --- | --- |
| `source` | 本地文件/目录，逗号或换行分隔，支持通配符；`!` 前缀为排除 | - | ✓ |
| `target` | 远端目标目录，支持逗号分隔多个 | - | ✓ |
| `rm` | 上传前删除目标目录 | `false` | |
| `strip_components` | 解包时剥离的路径层级 | `0` | |
| `overwrite` | `tar --overwrite` | `false` | |
| `tar_dereference` | `tar --dereference`（Windows 服务器需开启） | `false` | |
| `tar_tmp_path` | 远端临时包目录 | `/tmp/` | |
| `tar_exec` | 远端 tar 路径 | `tar` | |
| `debug` | 输出调试日志 | `false` | |
| `dry_run` | 只预演不实际传输 | `false` | |
| `capture_stdout` | 捕获远端 stdout 到 outputs | `false` | |

### 跳板机

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `proxy_host` | 跳板机地址 | - |
| `proxy_port` | 跳板机端口 | `22` |
| `proxy_username` | 跳板机用户名 | - |
| `proxy_password` | 跳板机密码 | - |
| `proxy_key` | 跳板机私钥全文 | - |
| `proxy_key_path` | 跳板机私钥路径 | - |
| `proxy_passphrase` | 跳板机私钥口令 | - |
| `proxy_fingerprint` | 跳板机指纹 | - |
| `proxy_timeout` | 跳板机连接超时 | `30s` |
| `proxy_use_insecure_cipher` | 跳板机启用不安全算法 | `false` |
| `proxy_cipher` | 跳板机加密算法 | - |

### 输出

| 输出 | 说明 |
| --- | --- |
| `stdout` | `capture_stdout: true` 时远端命令的标准输出 |
| `duration` | 本次传输耗时（秒） |

---

## 典型场景

### 多机部署

```yaml
- uses: PersiLiao/scp-action@v1
  with:
    host: "web1.example.com,web2.example.com:2222"
    username: deploy
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    source: "dist"
    target: "/opt/app"
    strip_components: 1
```

### 跳板机

```yaml
- uses: PersiLiao/scp-action@v1
  with:
    host: 10.0.0.10
    username: deploy
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    source: "dist/*"
    target: "/opt/app"
    proxy_host: bastion.example.com
    proxy_username: jump
    proxy_key: ${{ secrets.PROXY_KEY }}
    proxy_fingerprint: ${{ secrets.PROXY_FINGERPRINT }}
```

### 主机指纹校验

```bash
ssh-keyscan -t ed25519 example.com | ssh-keygen -lf -
# 256 SHA256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx example.com (ED25519)
```

```yaml
    fingerprint: "SHA256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

指纹不匹配时 Action 会直接失败，避免连到被劫持的主机。

### 只上传变更文件

```yaml
- uses: tj-actions/changed-files@v45
  id: changed
  with:
    separator: ","

- uses: PersiLiao/scp-action@v1
  with:
    host: ${{ secrets.HOST }}
    username: ${{ secrets.USERNAME }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    source: ${{ steps.changed.outputs.all_changed_files }}
    target: "/opt/app"
```

### Windows 服务器

```yaml
    tar_dereference: true
    target: "/c/Users/deploy/app"
```

远端需安装 Git for Windows，并将 OpenSSH 默认 shell 设为 Git Bash。

---

## 与 appleboy/scp-action 的差异

| 项目 | 本 Action | appleboy/scp-action |
| --- | --- | --- |
| 实现方式 | Docker + bash + 系统 SSH | composite + 运行时下载 `drone-scp` 二进制 |
| 外部网络依赖 | 无 | 需从 GitHub Releases 下载 |
| `version` / `curl_insecure` 参数 | 不需要（无下载环节） | 存在 |
| 传输失败时的降级 | `scp` 失败自动改用 `ssh stdin` 通道重试 | 无 |
| 传输语义 | 完全一致 | - |

---

## 安全建议

1. 优先使用密钥认证，密钥存放于 GitHub Secrets。
2. 生产环境务必配置 `fingerprint`。
3. 避免使用 `root` 登录，限制目标目录写权限。
4. 定期轮换部署密钥（建议 90 天）。

---

## 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| `Permission denied (publickey)` | 私钥格式/权限问题，或服务端禁用了 ssh-rsa；改用 ed25519 密钥 |
| `Connection refused` | 端口或防火墙问题 |
| `source 路径不存在` | 路径相对于 `GITHUB_WORKSPACE`，确认已执行 `actions/checkout` |
| `主机指纹不匹配` | 主机公钥已变更，重新采集指纹 |
| 上传卡住 | 调小 `timeout` / `command_timeout`，或开启 `debug` 查看 SSH 握手日志 |

---

## 许可证

[MIT](./LICENSE)
