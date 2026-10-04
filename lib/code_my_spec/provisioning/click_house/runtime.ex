defmodule CodeMySpec.Provisioning.ClickHouse.Runtime do
  @moduledoc false

  def execute(run, command, stage) do
    case run.([command]) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, "telemetry #{stage} failed (exit #{status})"}
    end
  end

  def capture(run, command, stage) do
    case run.([command]) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, status} -> {:error, "telemetry #{stage} failed (exit #{status})"}
    end
  end

  # Publish by rename so a failed transfer leaves the previous file intact.
  # The containing directory is private even when a container needs a
  # world-readable configuration file mounted from it.
  def write_file(run, path, content, mode \\ "600") do
    directory = Path.dirname(path)

    command =
      "set -eu\numask 077\n" <>
        "install -d -m 700 #{shell_quote(directory)}\n" <>
        "tmp=$(mktemp #{shell_quote(path <> ".XXXXXX")})\n" <>
        "trap 'rm -f \"$tmp\"' EXIT\n" <>
        "printf %s #{shell_quote(Base.encode64(content))} | base64 -d > \"$tmp\"\n" <>
        "chmod #{shell_quote(mode)} \"$tmp\"\n" <>
        "mv -f \"$tmp\" #{shell_quote(path)}\n"

    execute(run, command, "configuration delivery")
  end

  def ensure_container(run, name, image, arguments, configuration, startup_args \\ []) do
    digest = fingerprint([image, arguments, configuration, startup_args])
    startup = Enum.map_join(startup_args, " ", &shell_quote/1)
    container = shell_quote(name)

    command =
      """
      set -eu
      docker info >/dev/null
      if docker container inspect #{container} >/dev/null 2>&1; then
        owner=$(docker inspect --format '{{index .Config.Labels "cms.telemetry.managed"}}' #{container})
        test "$owner" = true
        current=$(docker inspect --format '{{index .Config.Labels "cms.telemetry.config"}}' #{container})
        if [ "$current" = #{shell_quote(digest)} ]; then
          running=$(docker inspect --format '{{.State.Running}}' #{container})
          if [ "$running" != true ]; then
            docker start #{container} >/dev/null
          fi
          exit 0
        fi
        docker pull #{shell_quote(image)} >/dev/null
        docker stop --time 30 #{container} >/dev/null
        docker rm #{container} >/dev/null
      else
        docker pull #{shell_quote(image)} >/dev/null
      fi
      docker run -d --name #{container} --restart always --log-driver local \
        --label cms.telemetry.managed=true \
        --label cms.telemetry.config=#{shell_quote(digest)} \
        #{arguments} #{shell_quote(image)} #{startup} >/dev/null
      """

    execute(run, command, "container reconciliation for #{name}")
  end

  def fingerprint(parts) do
    :crypto.hash(:sha256, :erlang.term_to_binary(parts))
    |> Base.encode16(case: :lower)
  end

  def shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
