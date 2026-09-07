# SCP Action

A GitHub Action that copies files and directories to one or many remote servers over SSH/SCP.

Implemented as a **Docker container action** with `openssh-client`, `sshpass` and GNU `tar` baked in — no reliance on runner preinstalled tooling and no binary downloaded at runtime.

[简体中文](./README_CN.md)

---

## Features

- **Key-based** and **password** authentication; private keys with passphrase supported
- **Parallel** transfer to multiple hosts (comma separated)
- **SSH jump host / proxy** support
- **Host key fingerprint verification** to prevent MITM attacks
- `strip_components`, `overwrite`, `rm`, `tar_dereference`, `!` exclude patterns
- `dry_run`, `debug`, `capture_stdout`
- Automatic rollback of remote temp files on failure
- Legacy server compatibility via `use_insecure_cipher`

---

## Quick Start

### SSH key (recommended)

```yaml
- name: Copy files to server
  uses: PersiLiao/scp-action@v1
  with:
    host: ${{ secrets.HOST }}
    username: ${{ secrets.USERNAME }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    port: 22
    source: "dist/*"
    target: "/opt/app"
```

### Password

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

## Copy Semantics (important)

This action follows the same semantics as `appleboy/scp-action` / `drone-scp`:

1. Sources are archived **exactly as written in `source`** (paths are preserved).
2. `--strip-components` is applied **on the remote side while extracting**.

| source | target | strip_components | Remote result |
| --- | --- | --- | --- |
| `tests/a.txt` | `/tmp/out` | `0` (default) | `/tmp/out/tests/a.txt` |
| `tests/a.txt` | `/tmp/out` | `1` | `/tmp/out/a.txt` |
| `dist/*` | `/opt/app` | `0` | `/opt/app/dist/...` |
| `dist` | `/opt/app` | `1` | `/opt/app/<contents of dist>` |

> To flatten a directory into the target, use `source: dist` with `strip_components: 1`.

`source` entries prefixed with `!` are passed to `tar --exclude`:

```yaml
source: |
  tests/*
  !tests/*.log
```

---

## Inputs

### Connection

| Input | Description | Default | Required |
| --- | --- | --- | --- |
| `host` | Remote host(s), comma separated, `host:port` supported | - | ✓ |
| `port` | SSH port | `22` | |
| `username` | SSH username | - | ✓ |
| `password` | Password authentication | - | |
| `key` | SSH private key content | - | |
| `key_path` | Path to SSH private key | - | |
| `passphrase` | Passphrase of the private key | - | |
| `fingerprint` | SHA256 fingerprint of host public key | - | |
| `protocol` | `tcp` / `tcp4` / `tcp6` | `tcp` | |
| `timeout` | SSH connection timeout | `30s` | |
| `command_timeout` | Timeout per remote command | `10m` | |
| `use_insecure_cipher` | Allow insecure ciphers (legacy servers) | `false` | |
| `cipher` | Force a specific cipher | - | |

> At least one of `password`, `key`, `key_path` must be provided.

### Transfer

| Input | Description | Default | Required |
| --- | --- | --- | --- |
| `source` | Local files/dirs, comma or newline separated, globs supported; `!` prefix excludes | - | ✓ |
| `target` | Remote target directory; comma separated for multiple | - | ✓ |
| `rm` | Remove target directory before upload | `false` | |
| `strip_components` | Leading path elements to strip | `0` | |
| `overwrite` | `tar --overwrite` | `false` | |
| `tar_dereference` | `tar --dereference` (needed for Windows servers) | `false` | |
| `tar_tmp_path` | Remote temp directory for the archive | `/tmp/` | |
| `tar_exec` | Remote tar executable | `tar` | |
| `debug` | Verbose output | `false` | |
| `dry_run` | Print the plan without transferring | `false` | |
| `capture_stdout` | Capture remote stdout into outputs | `false` | |

### Jump host (proxy)

| Input | Description | Default |
| --- | --- | --- |
| `proxy_host` | Jump host address | - |
| `proxy_port` | Jump host port | `22` |
| `proxy_username` | Jump host username | - |
| `proxy_password` | Jump host password | - |
| `proxy_key` | Jump host private key content | - |
| `proxy_key_path` | Path to jump host private key | - |
| `proxy_passphrase` | Jump host key passphrase | - |
| `proxy_fingerprint` | Jump host fingerprint | - |
| `proxy_timeout` | Jump host connect timeout | `30s` |
| `proxy_use_insecure_cipher` | Allow insecure ciphers on proxy | `false` |
| `proxy_cipher` | Proxy cipher | - |

### Outputs

| Output | Description |
| --- | --- |
| `stdout` | Remote stdout when `capture_stdout: true` |
| `duration` | Transfer duration in seconds |

---

## Examples

### Multiple servers

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

### Jump host

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

### Host key fingerprint

```bash
ssh-keyscan -t ed25519 example.com | ssh-keygen -lf -
# 256 SHA256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx example.com (ED25519)
```

```yaml
    fingerprint: "SHA256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

A mismatch fails the action immediately.

### Changed files only

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

### Windows server

```yaml
    tar_dereference: true
    target: "/c/Users/deploy/app"
```

Install Git for Windows on the remote and set Git Bash as the OpenSSH default shell.

---

## Differences from appleboy/scp-action

| | This action | appleboy/scp-action |
| --- | --- | --- |
| Implementation | Docker + bash + system SSH | composite + downloads `drone-scp` binary |
| External network needed at runtime | No | Yes (GitHub Releases) |
| `version` / `curl_insecure` inputs | Not needed | Present |
| Fallback when `scp` fails | Retries over an `ssh` stdin channel | None |
| Copy semantics | Identical | - |

---

## Security Recommendations

1. Prefer SSH keys stored in GitHub Secrets.
2. Always set `fingerprint` in production.
3. Do not log in as `root`; restrict write permissions on the target directory.
4. Rotate deployment keys regularly (90 days is a good cadence).

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Permission denied (publickey)` | Key format/permissions, or ssh-rsa disabled server-side — switch to ed25519 |
| `Connection refused` | Wrong port or firewall |
| `source path does not exist` | Paths are relative to `GITHUB_WORKSPACE`; make sure `actions/checkout` ran |
| `host key fingerprint mismatch` | Host key changed — re-collect the fingerprint |
| Transfer hangs | Lower `timeout` / `command_timeout`, or enable `debug` |

---

## License

[MIT](./LICENSE)
