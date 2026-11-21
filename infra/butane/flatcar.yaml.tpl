variant: flatcar
version: 1.1.0

passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - ${ssh_public_key}

storage:
  files:
    # SSH: keys only. Read before Flatcar's own sshd_config.d files (sshd keeps the first value it sees), so no
    # password or keyboard-interactive (PAM) login exists whatever the defaults say (the SSH port is open to the world).
    - path: /etc/ssh/sshd_config.d/01-key-only.conf
      mode: 0644
      contents:
        inline: |
          # anvil: keys only (infra/butane/flatcar.yaml.tpl). Read before Flatcar defaults (first value wins).
          PasswordAuthentication no
          KbdInteractiveAuthentication no
          AuthenticationMethods publickey
    - path: /etc/sysctl.d/80-swappiness.conf
      contents:
        inline: |
          vm.swappiness=10

    # Flatcar's default of 128 inotify instances per user is far too low for a
    # node running dozens of pods (kubelet, log followers, Dozzle): it fails with
    # "failed to create fsnotify watcher: too many open files".
    - path: /etc/sysctl.d/80-inotify.conf
      contents:
        inline: |
          fs.inotify.max_user_instances=8192
          fs.inotify.max_user_watches=524288

%{ if registry_password != "" ~}
    # Pull auth for the private Scaleway registry, read by k3s' containerd at
    # start-up (k3s' equivalent of `docker login rg.<region>.scw.cloud`).
    - path: /etc/rancher/k3s/registries.yaml
      mode: 0600
      contents:
        source: data:text/plain;base64,${registries_yaml_b64}

%{ endif ~}
%{ if tailscale_version != "" ~}
    # Tailscale from Flatcar's sysext-bakery: /usr is read-only, so it ships as
    # a system extension merged into /usr by systemd-sysext at boot.
    - path: /opt/extensions/tailscale/tailscale-${tailscale_version}-x86-64.raw
      mode: 0644
      contents:
        source: https://github.com/flatcar/sysext-bakery/releases/download/tailscale-${tailscale_version}/tailscale-${tailscale_version}-x86-64.raw
    # The extension's tailscaled.service requires this EnvironmentFile but
    # doesn't ship it (Tailscale's stock defaults).
    - path: /etc/default/tailscaled
      mode: 0644
      contents:
        inline: |
          PORT="41641"
          FLAGS=""
%{ if tailscale_auth_key != "" ~}
    - path: /etc/tailscale/authkey
      mode: 0600
      contents:
        source: data:text/plain;base64,${tailscale_auth_key_b64}
%{ endif ~}

%{ endif ~}
    # Read by k3s.service / k3s-agent.service (created by the installer below).
    # flannel-iface pins the pod network to the private network NIC (Flatcar
    # names interfaces eth0=public, eth1=private).
    - path: /etc/rancher/k3s/config.yaml
      mode: 0600
      contents:
        inline: |
%{ if role == "server" ~}
          token: "${k3s_token}"
          node-ip: "${node_ip}"
          flannel-iface: "eth1"
          tls-san:
            - "${domain}"
          # ServiceLB only exposes 80/443 on nodes carrying this label,
          # i.e. only the master.
          node-label:
            - "svccontroller.k3s.cattle.io/enablelb=true"
%{ else ~}
          server: "https://${master_private_ip}:6443"
          token: "${k3s_token}"
          node-ip: "${node_ip}"
          flannel-iface: "eth1"
%{ if node_pool != "" ~}
          # A node pool (infra/pools.tf): only pods that tolerate the taint (and select the label) run here.
          node-label:
            - "anvil/pool=${node_pool}"
%{ if node_trusted != "" ~}
            # Trusted pool: may hold Secrets; the block-agents NetworkPolicies don't refuse it.
            - "anvil/trusted=true"
%{ endif ~}
          node-taint:
            - "anvil/dedicated=${node_pool}:NoSchedule"
%{ else ~}
          # Optional cheap worker for light, interruptible work only: nothing lands here unless its pod
          # tolerates the taint (and asks for the label), so the platform and the apps stay on the master.
          node-label:
            - "anvil/role=light"
          node-taint:
            - "anvil/light=true:NoSchedule"
%{ endif ~}
%{ endif ~}
          # Image GC: once the disk is 75% full, delete unused images down to
          # 65% (kubelet defaults are 85/80).
          kubelet-arg:
            - "fail-swap-on=false"
            - "image-gc-high-threshold=75"
            - "image-gc-low-threshold=65"
%{ if role == "server" ~}

    # k3s auto-applies everything in server/manifests/ (servers only).
    - path: /var/lib/rancher/k3s/server/manifests/traefik-config.yaml
      mode: 0600
      contents:
        source: data:text/plain;base64,${traefik_config_b64}

%{ if origin_pull_b64 != "" ~}

    # Authenticated Origin Pulls (manifests/origin-pull.yaml.tpl).
    - path: /var/lib/rancher/k3s/server/manifests/origin-pull.yaml
      mode: 0600
      contents:
        source: data:text/plain;base64,${origin_pull_b64}
%{ endif ~}
%{ endif ~}
%{ if tailscale_version != "" ~}

  links:
    - path: /etc/extensions/tailscale.raw
      target: /opt/extensions/tailscale/tailscale-${tailscale_version}-x86-64.raw
      hard: false
%{ endif ~}

systemd:
  units:
    # SSH on a non-standard port (Flatcar's sshd is socket-activated). The
    # empty ListenStream= clears the default :22 first.
    - name: sshd.socket
      dropins:
        - name: 10-port.conf
          contents: |
            [Socket]
            ListenStream=
            ListenStream=${ssh_port}

    # k3s (and with it every app) must always come back: the installer's unit already has Restart=always; this
    # drops systemd's start limit so it keeps retrying forever, however often it fails. It's enabled at boot by the
    # installer (k3s-install.service below).
    - name: k3s.service
      dropins:
        - name: 20-restart-forever.conf
          contents: |
            [Unit]
            StartLimitIntervalSec=0
            [Service]
            Restart=always
            RestartSec=5s
    - name: k3s-agent.service
      dropins:
        - name: 20-restart-forever.conf
          contents: |
            [Unit]
            StartLimitIntervalSec=0
            [Service]
            Restart=always
            RestartSec=5s

    # Requirement: no automatic OS updates.
    - name: update-engine.service
      mask: true
    - name: locksmithd.service
      mask: true

    # Swapfile pattern from the Flatcar docs (cycle-free, see flatcar/Flatcar#133), fixed for reboots: the docs'
    # `mkswap --size … --file` only works when the file doesn't exist yet and fails on every later boot ("cannot set
    # permissions on swap file"), leaving the node without swap. So the file is created once and later boots only
    # re-initialise it (swap holds no persistent data). Resize with scripts/node.sh swap <MiB>.
    - name: create-swapfile.service
      contents: |
        [Unit]
        Description=Create a ${swap_size_mb}MiB swapfile at /var/swapfile
        RequiresMountsFor=/var
        DefaultDependencies=no

        [Service]
        Type=oneshot
        ExecStart=/bin/sh -c 'if [ -f /var/swapfile ]; then exec /usr/sbin/mkswap /var/swapfile; else exec /usr/sbin/mkswap --size ${swap_size_mb}m --file /var/swapfile; fi'
        RemainAfterExit=true

    - name: var-swapfile.swap
      enabled: true
      contents: |
        [Unit]
        Description=Turn on swap
        BindsTo=create-swapfile.service
        After=create-swapfile.service

        [Swap]
        What=/var/swapfile

        [Install]
        WantedBy=multi-user.target

    # Flatcar's /usr is read-only, so k3s goes to /opt/bin. The installer
    # creates and starts k3s.service (or k3s-agent.service) itself; the retry
    # loop covers transient network failures right after boot — and, on
    # agents, waits out the master not being up yet.
    - name: k3s-install.service
      enabled: true
      contents: |
        [Unit]
        Description=Install k3s (${role})
        Wants=network-online.target
        After=network-online.target
        ConditionPathExists=!/opt/bin/k3s

        [Service]
        Type=oneshot
        RemainAfterExit=true
        Environment=INSTALL_K3S_BIN_DIR=/opt/bin
%{ if k3s_version != "" ~}
        Environment=INSTALL_K3S_VERSION=${k3s_version}
%{ else ~}
        Environment=INSTALL_K3S_CHANNEL=${k3s_channel}
%{ endif ~}
%{ if role == "agent" ~}
        Environment=INSTALL_K3S_EXEC=agent
%{ endif ~}
        # Flatcar has SELinux in permissive mode but no k3s-selinux policy
        # package; without these the installer hard-fails its policy check.
        Environment=INSTALL_K3S_SKIP_SELINUX_RPM=true
        Environment=INSTALL_K3S_SELINUX_WARN=true
        ExecStart=/usr/bin/bash -c 'until curl -sfL https://get.k3s.io | sh -; do echo "k3s install failed, retrying in 15s"; sleep 15; done'

        [Install]
        WantedBy=multi-user.target
%{ if tailscale_version != "" ~}

    # tailscaled.service only exists once systemd-sysext has merged the
    # extension, so it can't be enabled by Ignition directly. This enables it
    # after the merge and, on first boot with an auth key, joins the tailnet.
    # Without a key: `sudo tailscale up --hostname=${hostname}` once by hand,
    # then `sudo tailscale serve --bg --https=443 http://127.0.0.1:18080` (Dozzle) and
    # `sudo tailscale serve --bg --https=8443 http://10.43.200.93:9093` (Alertmanager) and
    # `sudo tailscale serve --bg --https=9443 http://10.43.200.90:9090` (Prometheus) and
    # `sudo tailscale serve --bg --https=3443 http://10.43.200.94:3000` (Grafana), all platform/alerting.
    # `sudo tailscale serve --bg --https=8446 http://10.43.200.97:8080` (autopilot-viewer: every autopilot run, platform/webhook).
    - name: tailscale-bootstrap.service
      enabled: true
      contents: |
        [Unit]
        Description=Enable tailscaled from the sysext and join the tailnet
        Wants=network-online.target
        After=systemd-sysext.service network-online.target
        ConditionPathExists=!/var/lib/tailscale/.joined

        [Service]
        Type=oneshot
        RemainAfterExit=true
        ExecStart=/usr/bin/systemctl enable --now tailscaled.service
        ExecStart=/usr/bin/bash -c 'if [ -s /etc/tailscale/authkey ]; then until tailscale up --hostname=${hostname} --auth-key="$(cat /etc/tailscale/authkey)"; do sleep 10; done; touch /var/lib/tailscale/.joined; fi'
        # Dozzle (platform/dozzle) listens on 127.0.0.1:18080 only; publish it to the
        # tailnet and nowhere else. The serve config persists in tailscaled's state.
        # Needs "Serve" enabled once in the tailnet admin (HUMAN.md H11).
        ExecStart=-/usr/bin/bash -c 'if [ -f /var/lib/tailscale/.joined ]; then tailscale serve --bg --https=443 http://127.0.0.1:18080; tailscale serve --bg --https=8443 http://10.43.200.93:9093; tailscale serve --bg --https=9443 http://10.43.200.90:9090; tailscale serve --bg --https=3443 http://10.43.200.94:3000; tailscale serve --bg --https=8446 http://10.43.200.97:8080; fi'

        [Install]
        WantedBy=multi-user.target
%{ endif ~}
