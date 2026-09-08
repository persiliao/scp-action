# syntax=docker/dockerfile:1

FROM alpine:3.20

# openssh-client : ssh / scp / ssh-keygen / ssh-keyscan / ssh-agent / ssh-add
# sshpass        : enable password auth (non-interactive password supply)
# tar / gzip     : GNU tar provides --overwrite / --dereference / --strip-components
# coreutils      : provides timeout command for command_timeout
# bash           : entrypoint relies on bash arrays and other features
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
