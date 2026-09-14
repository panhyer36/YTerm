# Disposable Ubuntu sshd for testing YTerm (key + password auth, rsync/tar/zip installed).
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server rsync zip unzip xz-utils bzip2 zstd && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd
RUN useradd -m -s /bin/bash tester && echo 'tester:testpass' | chpasswd
RUN mkdir -p /home/tester/.ssh && chmod 700 /home/tester/.ssh
COPY authorized_keys /home/tester/.ssh/authorized_keys
RUN sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
RUN mkdir -p "/home/tester/測試 資料夾/sub dir" && echo hello > "/home/tester/測試 資料夾/hello.txt" \
 && ln -s "測試 資料夾" /home/tester/linkdir && dd if=/dev/urandom of=/home/tester/random.bin bs=1M count=8 \
 && chown -R tester:tester /home/tester && chmod 600 /home/tester/.ssh/authorized_keys
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
