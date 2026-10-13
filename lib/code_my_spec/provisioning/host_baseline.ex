defmodule CodeMySpec.Provisioning.HostBaseline do
  @moduledoc false

  alias CodeMySpec.Provisioning.ClickHouse.Runtime

  def ensure(run) do
    with :ok <- execute(run, docker_command(), "Docker logging configuration") do
      execute(run, swap_command(), "small-server swap configuration")
    end
  end

  # Also used by registry trust so a later deploy cannot erase logging defaults.
  def docker_command(registry \\ nil) do
    script = ~S"""
    import fcntl, json, os, subprocess, sys, tempfile

    os.makedirs('/etc/docker', exist_ok=True)
    with open('/etc/docker/.cms-config.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = '/etc/docker/daemon.json'
        existed = os.path.exists(path)
        previous = open(path, 'rb').read() if existed else None
        config = json.loads(previous) if existed else {}
        if not isinstance(config, dict):
            raise ValueError('Docker configuration must be an object')
        desired = dict(config)
        desired['log-driver'] = 'local'
        desired['log-opts'] = {'max-size': '20m', 'max-file': '5', 'compress': 'true'}
        registry = json.loads(sys.argv[1])
        if registry is not None:
            registries = desired.get('insecure-registries', [])
            if not isinstance(registries, list):
                raise ValueError('insecure-registries must be a list')
            desired['insecure-registries'] = list(dict.fromkeys(registries + [registry]))
        changed = desired != config
        if changed:
            fd, temporary = tempfile.mkstemp(prefix='.cms-daemon-', dir='/etc/docker')
            try:
                with os.fdopen(fd, 'w') as output:
                    json.dump(desired, output)
                    output.write('\n')
                subprocess.run(['dockerd', '--validate', '--config-file', temporary], check=True, stdout=subprocess.DEVNULL)
                os.chmod(temporary, 0o644)
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        active = subprocess.run(['docker', 'info', '--format', '{{.LoggingDriver}}'], capture_output=True, text=True)
        if changed or active.returncode != 0 or active.stdout.strip() != 'local':
            result = subprocess.run(['systemctl', 'restart', 'docker'])
            if result.returncode != 0:
                if changed:
                    if existed:
                        with open(path, 'wb') as output:
                            output.write(previous)
                    else:
                        os.unlink(path)
                    subprocess.run(['systemctl', 'restart', 'docker'])
                raise SystemExit(result.returncode)
    """

    "python3 -c " <>
      Runtime.shell_quote(script) <>
      " " <>
      Runtime.shell_quote(Jason.encode!(registry))
  end

  def swap_command do
    ~S"""
    set -eu
    exec 9>/run/cms-swap.lock
    flock 9
    memory_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
    if [ "$memory_kb" -gt 4718592 ] || [ "$swap_kb" -gt 0 ]; then exit 0; fi
    path=/swapfile-cms
    if [ ! -e "$path" ]; then
      umask 077
      tmp=$(mktemp /swapfile-cms.XXXXXX)
      trap 'rm -f "$tmp"' EXIT
      dd if=/dev/zero of="$tmp" bs=1M count=4096 status=none
      chmod 600 "$tmp"
      mkswap "$tmp" >/dev/null
      mv "$tmp" "$path"
    fi
    test -f "$path" && test ! -L "$path"
    test "$(blkid -p -s TYPE -o value "$path")" = swap
    chmod 600 "$path"
    if ! awk '$1 == "/swapfile-cms" {found=1} END {exit !found}' /etc/fstab; then
      printf '%s\n' '/swapfile-cms none swap sw 0 0' >> /etc/fstab
    fi
    swapon "$path"
    """
  end

  defp execute(run, command, stage) do
    case run.([command]) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, "#{stage} failed (exit #{status})"}
    end
  end
end
