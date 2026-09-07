# syntax=docker/dockerfile:1

FROM alpine:3.20

# openssh-client : ssh / scp / ssh-keygen / ssh-keyscan / ssh-agent / ssh-add
# sshpass        : 支持密码认证（非交互提供密码）
# tar / gzip     : GNU tar，提供 --overwrite / --dereference / --strip-components
# coreutils      : timeout 命令，用于 command_timeout
# bash           : entrypoint 依赖 bash 数组等特性
RUN apk add --no-cache \
      bash \
      ca-certificates \
      coreutils \
      gzip \
      openssh-client \
      sshpass \
      tar

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
