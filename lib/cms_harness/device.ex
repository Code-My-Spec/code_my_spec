defmodule CmsHarness.Device do
  @moduledoc """
  This machine's identity, established when the harness comes up.

  One file, `device.json` in `CmsHarness.Config.local_state_dir/0`, never
  inside a working copy: a machine is a machine whether or not it has a
  checkout, and a per-checkout identity would make every worktree a machine.

  The id is minted here, once, and never re-asked: `fresh_id/0` runs only when
  nothing is on file, `write/1` refuses to move an id already on file, and a
  server reply that disagrees is logged and ignored. It prefers a hardware
  address, so a lost `device.json` recomputes the same id.

  Failure is soft: a harness that cannot announce still serves. The id is
  written when minted, not when the server replies, so an unreachable server
  never leaves the machine without one. See knowledge/harness, "Device".
  """

  require Logger
  import Bitwise, only: [band: 2]

  alias CmsHarness.Config
  alias CmsHarness.Device.Client
  alias CmsHarness.Token

  @doc """
  Announce this machine and keep the identity it is issued.

  Returns `{:ok, %{device_id: id, working_copies: %{id => root}, pending_local_projects: [...]}}`,
  or `{:error, reason}` when the server could not be reached or refused. Safe
  to call on every boot: presenting the id we already hold is how the server
  recognises the machine rather than minting another.

  `working_copies` is what the *server* believes is on this machine, which is
  the half of the exchange the harness cannot work out for itself — see
  `CmsHarness.WorkingCopyReporter`.

  `pending_local_projects` is passed through unread for `WorkingCopyReporter`.

  `observations` (`%{working_copy_id => present?}`) is an argument because
  observation needs memory of served copies, which lives in the reporter: a
  removed copy can no longer name itself. Re-announcing with it is how a
  removed worktree is noticed.
  """

  @spec announce(%{optional(String.t()) => boolean()}, String.t() | nil) ::
          {:ok,
           %{
             device_id: String.t(),
             working_copies: %{String.t() => String.t()},
             pending_local_projects: [
               %{id: String.t(), name: String.t(), app_name: String.t(), deploy_key: String.t()}
             ]
           }}
          | {:error, term()}
  def announce(observations \\ %{}, token \\ nil) do
    # Recorded before the round trip: the join payload reads `recorded_id/0`,
    # and a random fallback id must not be re-minted on every announce.
    id = ensure_id()

    with {:ok, token} <- credential(token),
         {:ok, %{device_id: confirmed} = reply} <- post(id, token, observations) do
      write(confirmed || id)
      Logger.info("[CmsHarness] this machine is device #{confirmed || id}")
      {:ok, reply}
    else
      {:error, reason} = error ->
        Logger.warning(
          "[CmsHarness] could not announce this machine (#{inspect(reason)}); " <>
            "it is device #{id} and knows it, but will not appear in the device " <>
            "list until an announce reaches the server"
        )

        error
    end
  end

  # The id on file, minting and recording one if there is none.
  #
  # Safe from several daemons at once: the first write decides.
  @doc "Return this machine's persistent identity, creating it before authorization if needed."
  @spec ensure_id() :: String.t()
  def ensure_id do
    case recorded_id() do
      nil ->
        minted = fresh_id()
        write(minted)
        # Re-read: another daemon may have written first.
        recorded_id() || minted

      id ->
        id
    end
  end

  @doc "The identity this machine already holds, or nil."
  @spec recorded_id() :: String.t() | nil
  def recorded_id do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"device_id" => id}} when is_binary(id) and id != "" <- Jason.decode(body) do
      id
    else
      _ -> nil
    end
  end

  # A hardware fingerprint (recomputable after a lost file), else a random id.
  # Only for the user's own state dir: a harness given its own (a workspace,
  # or several QA harnesses on one machine) is its own device, and the
  # fingerprint would make them all one.
  defp fresh_id do
    (not Config.own_state?() && machine_fingerprint()) || Ecto.UUID.generate()
  end

  # The lowest non-loopback, non-zero MAC from `:inet.getifaddrs/0` (portable,
  # no shell-out), preferring globally-unique addresses over locally
  # administered ones (virtual adapters that come and go). Hashed to 16 bytes
  # for UUID shape only. See knowledge/harness, "Device".
  defp machine_fingerprint do
    with {:ok, interfaces} <- :inet.getifaddrs(),
         mac when is_binary(mac) <- interfaces |> Enum.flat_map(&hwaddr/1) |> pick_mac(),
         {:ok, uuid} <- mac |> then(&:crypto.hash(:md5, &1)) |> Ecto.UUID.load() do
      uuid
    else
      _ -> nil
    end
  end

  # Public so the selection can be tested against synthetic addresses.
  @doc false
  @spec pick_mac([binary()]) :: binary() | nil
  def pick_mac(candidates) do
    case candidates |> Enum.reject(&locally_administered?/1) |> Enum.sort() do
      [mac | _] -> mac
      [] -> candidates |> Enum.sort() |> List.first()
    end
  end

  defp locally_administered?(<<first, _rest::binary>>), do: band(first, 0x02) != 0

  defp hwaddr({_name, opts}) do
    with false <- :loopback in Keyword.get(opts, :flags, []),
         [_ | _] = bytes <- Keyword.get(opts, :hwaddr, []),
         false <- Enum.all?(bytes, &(&1 == 0)) do
      [:binary.list_to_bin(bytes)]
    else
      _ -> []
    end
  end

  @doc """
  Where the identity is kept.

  Under `Config.local_state_dir/0`, which is not always `~/.codemyspec`.
  Overridable (`:device_config_path`) so a test can point it somewhere
  disposable.
  """
  @spec path() :: String.t()
  def path do
    # `||`, not a `get_env/3` default: a test may leave the key set to `nil`,
    # and this is on the reconnect path.
    (Application.get_env(:code_my_spec, :device_config_path) ||
       Path.join(Config.local_state_dir(), "device.json"))
    |> Path.expand()
  end

  # "cloud" when pinned to one project (a sprite), else "local".
  defp kind do
    case Application.get_env(:code_my_spec, :project_id) do
      nil -> "local"
      _pinned -> "cloud"
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> nil
    end
  end

  # A caller already holding a token passes it: onboarding a fresh machine has
  # exchanged the project's deploy key, but nothing `Token.access_token/0`
  # consults knows that key until the copy is written.
  defp credential(token) when is_binary(token) and token != "", do: {:ok, token}

  defp credential(_token) do
    case Token.access_token() do
      {:ok, token} -> {:ok, token}
      _ -> Config.credential()
    end
  end

  # Through the client seam, never straight at `Req`, so tests never call a
  # live server.
  defp post(device_id, token, observations) do
    Client.impl().announce(device_id, token, %{
      hostname: hostname(),
      kind: kind(),
      working_copies: observations
    })
  end

  # Refuses to move an id already on file; the first writer settles it.
  # `persist/1` merges over the file so unknown fields survive.
  defp write(id) do
    case recorded_id() do
      nil ->
        persist(id)

      ^id ->
        :ok

      other ->
        Logger.warning(
          "[CmsHarness] server confirmed device #{id} but this machine already " <>
            "holds #{other}; keeping #{other}"
        )

        :ok
    end
  end

  defp persist(id) do
    file = path()
    existing = if File.exists?(file), do: Jason.decode!(File.read!(file)), else: %{}
    body = existing |> Map.put("device_id", id) |> Jason.encode!(pretty: true)

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, body <> "\n") do
      # It sits beside a credential and names a machine; not world-readable.
      File.chmod(file, 0o600)
    end
  end
end
