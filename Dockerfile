# Image for the auditd-config DaemonSet. Node changes happen via chroot /host,
# so this only needs bash + coreutils (base) plus curl/jq for the taint removal.
FROM mcr.microsoft.com/azurelinux/base/core:3.0
RUN tdnf install -y curl jq && tdnf clean all
