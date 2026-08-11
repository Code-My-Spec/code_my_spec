# A box: something with an sshd and a Docker daemon, which is all our
# provisioning code ever assumed a server was.
#
# Built on `dind` rather than mounting the host's Docker socket, and the
# difference matters. `Registry.trust_command/1` writes to /etc/docker/daemon.json
# and restarts the daemon so a plain-HTTP registry becomes pushable — against a
# mounted host socket that edit lands in a container that owns no daemon, so it
# does nothing, and the push then fails as `context deadline exceeded`. Which is
# exactly the timeout-that-looks-like-a-network-problem the real code has a
# comment about. A box with its own daemon either trusts the registry or does
# not, the same way the cloud one does.
#
# The cost is `privileged: true` in the compose file. That is a real grant, and
# it is why this listens on loopback only and holds a key that is generated per
# machine and never committed.
FROM docker:28-dind

# git and tar are for `ssh_deliver/2` — it pipes `git archive` into `tar -x`
# on the far side. iproute2/iputils/curl are for `where_am_i/2`, which only
# runs when a push fails; a box that cannot answer those questions turns a
# diagnostic into a second failure.
RUN apk add --no-cache openssh bash git tar iproute2 iputils curl

RUN ssh-keygen -A \
 && mkdir -p /root/.ssh && chmod 700 /root/.ssh \
 && printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\nUseDNS no\n' \
      > /etc/ssh/sshd_config.d/fleet.conf

COPY entrypoint.sh /usr/local/bin/fleet-entrypoint
RUN chmod +x /usr/local/bin/fleet-entrypoint

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/fleet-entrypoint"]
