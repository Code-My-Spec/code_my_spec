defmodule CodeMySpec.Servers.Containers do
  @moduledoc """
  What is running on a server, according to the server.

  ## Why this never reads our records

  A deploy is a single moment; a container's life is everything after it. The
  deploy that started a container succeeded — that record is true and will stay
  true through every crash, restart and `docker stop` that follows. Reporting
  it as "what is running" would be right exactly once, at the moment it
  happened, and wrong from then on.

  So this asks the box. Same doctrine as `Servers.list/1` asking Hetzner rather
  than reading `linked_servers`, one level in.

  ## Why `-a`

  `docker ps` without it hides stopped containers, which is precisely the one
  worth finding. A page built from the default listing shows a healthy box with
  one service quietly absent, and absent reads as "I misremembered what I
  deployed" rather than as "it died at 3am".

  ## Three failures, not one

  - `:no_access_key` — the account has no key, so nothing was ever going to work
  - `:not_permitted` — we have a key and the box rejected it, which is the
    normal state of a machine Sam built by hand before he adds ours
  - `:timeout` — the box accepted a connection and never answered

  They are kept apart because they need different things from him: nothing, a
  key, and a look at the machine respectively. Collapsing them into "could not
  connect" would tell him only that something is wrong.
  """

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.TempFile
  alias CodeMySpec.Users.Scope

  @access_key_private "server_ssh_private_key"

  # Long enough for a loaded box, short enough that nobody watches a spinner
  # wondering whether it is broken. The read gives up on its own rather than
  # leaving the page to decide, so "we stopped waiting" is an answer the caller
  # receives rather than a state it has to infer.
  @connect_timeout_seconds 5
  @read_timeout_ms 10_000

  @type container :: %{
          name: String.t(),
          image: String.t(),
          state: String.t(),
          status: String.t(),
          exit_code: integer() | nil
        }

  @doc """
  Every container the box reports, running or not.

  Injectable so a criterion about how a crash is displayed does not need a box
  with a real Docker daemon. The page itself is always driven for real.
  """
  @spec list(Scope.t(), map()) :: {:ok, [container()]} | {:error, term()}
  def list(%Scope{} = scope, server) do
    case config(:list) do
      nil -> read(scope, server)
      fun -> fun.(scope, server)
    end
  end

  defp read(_scope, %{ip: nil}), do: {:error, :no_address}

  defp read(scope, %{ip: ip}) when is_binary(ip) do
    with {:ok, key} <- access_key(scope) do
      with_key_file(key, fn path -> docker_ps(ip, path) end)
    end
  end

  defp read(_scope, _server), do: {:error, :no_address}

  defp access_key(scope) do
    case AccountSecrets.fetch_value(scope, @access_key_private) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :no_access_key}
    end
  end

  # 0600 and gone afterwards. `ssh` refuses a key any wider than that, and a
  # private key outliving the read it was written for is a worse problem than
  # the read failing.
  defp with_key_file(key, fun) do
    dir = TempFile.dir("cms-key")
    File.mkdir_p!(dir)
    path = Path.join(dir, "id_ed25519")

    try do
      File.write!(path, key)
      File.chmod!(path, 0o600)
      fun.(path)
    after
      File.rm_rf(dir)
    end
  end

  defp docker_ps(ip, key_path) do
    args = [
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "-o",
      "BatchMode=yes",
      # Without this, `-i` is a suggestion: ssh still offers whatever the
      # agent holds. On a developer's laptop that quietly succeeds using their
      # personal key and the page looks like it works, while the same code on
      # the server — no agent, no keys — cannot get in. The read has to
      # authenticate as the credential it claims to use, or it is not testing
      # anything the deployment will experience.
      "-o",
      "IdentitiesOnly=yes",
      "-o",
      "ConnectTimeout=#{@connect_timeout_seconds}",
      "-i",
      key_path,
      "root@#{ip}",
      "docker ps -a --format '{{json .}}'"
    ]

    case run(args) do
      {:ok, {output, 0}} -> {:ok, parse(output)}
      {:ok, {output, status}} -> {:error, classify(output, status)}
      :timeout -> {:error, :timeout}
    end
  end

  # `ConnectTimeout` covers a box that refuses or drops the connection. It does
  # nothing for one that completes the handshake and then stops answering, and
  # that is the case this outer deadline exists for.
  defp run(args) do
    task = Task.async(fn -> System.cmd("ssh", args, stderr_to_stdout: true) end)

    case Task.yield(task, @read_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      _ -> :timeout
    end
  end

  defp classify(output, status) do
    cond do
      output =~ "Permission denied" or output =~ "publickey" -> :not_permitted
      output =~ "Connection timed out" or output =~ "Operation timed out" -> :timeout
      output =~ "Connection refused" or output =~ "No route to host" -> :unreachable
      output =~ "docker: command not found" -> :no_docker
      true -> {:ssh_failed, status, String.trim(output)}
    end
  end

  defp parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, entry} -> [normalise(entry)]
        # A box can print a banner or a warning before the JSON. Skipping what
        # will not parse beats failing the whole read over a login message.
        {:error, _} -> []
      end
    end)
  end

  defp normalise(entry) do
    status = entry["Status"] || ""

    %{
      name: entry["Names"],
      image: entry["Image"],
      state: String.downcase(entry["State"] || ""),
      status: status,
      exit_code: exit_code(status)
    }
  end

  # Docker reports the code inside the status string — "Exited (1) 2 hours ago"
  # — and nowhere else in `ps` output. It is the difference between a container
  # somebody stopped and one that fell over, so it is worth digging out.
  defp exit_code(status) do
    case Regex.run(~r/Exited \((\d+)\)/, status) do
      [_, code] -> String.to_integer(code)
      nil -> nil
    end
  end

  defp config(key), do: Application.get_env(:code_my_spec, __MODULE__, [])[key]
end
