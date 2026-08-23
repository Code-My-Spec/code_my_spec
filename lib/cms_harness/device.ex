defmodule CmsHarness.Device do
  @moduledoc """
  This machine's identity, established when the harness comes up.

  One file, `~/.codemyspec/device.json`, beside `harness_secret` and
  deliberately **not** inside any working copy.

  ## Why the install and not the checkout

  Two reasons, and the second is the one that would have bitten.

  A machine is a machine whether or not it has a checkout on it. Announcing per
  working copy — which is what the first cut of this did, on the
  `harness_project:` join — makes a box appear only once something is checked
  out on it, and mints a *new* machine per checkout after that. Eight worktrees
  on one laptop would have been eight laptops.

  And `.cms_harness.json` lives in the repository, so it clones. Story 891's
  criterion 2353 exists because of that: a clone inheriting the identity of the
  copy it came from. A file outside every checkout cannot be cloned at all,
  which turns that whole class into something the placement handles rather than
  something a guard has to catch.

  ## The id is issued, never invented

  Same argument as `WorkingCopies.issue/3`, one level up. A hostname is
  generated for exactly the containers that would collide; a MAC address does
  not survive a re-image; a path is not identity. So the machine announces what
  it holds — or nothing — and keeps whatever it is told.

  ## Failure is soft on purpose

  A harness that cannot reach the server still has work to do: it watches files,
  runs analyzers and answers hooks against whatever it already knows. Refusing
  to boot because a machine could not announce itself would trade a cosmetic gap
  in a list for the whole harness, so this logs and carries on.
  """

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.Device.Client
  alias CmsHarness.Token

  @default_path "~/.codemyspec/device.json"

  @doc """
  Announce this machine and keep the identity it is issued.

  Returns `{:ok, device_id}`, or `{:error, reason}` when the server could not be
  reached or refused. Safe to call on every boot: presenting the id we already
  hold is how the server recognises the machine rather than minting another.
  """
  @spec announce() :: {:ok, String.t()} | {:error, term()}
  def announce do
    with {:ok, token} <- credential(),
         {:ok, id} <- post(recorded_id(), token) do
      write(id)
      Logger.info("[CmsHarness] this machine is device #{id}")
      {:ok, id}
    else
      {:error, reason} = error ->
        Logger.warning(
          "[CmsHarness] could not announce this machine (#{inspect(reason)}); " <>
            "it will not appear in the device list until the next start that reaches the server"
        )

        error
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

  @doc """
  Where the identity is kept.

  Overridable so a test can point it somewhere disposable — the same seam
  `harness_secret_path` has, and for the same reason.
  """
  @spec path() :: String.t()
  def path do
    Application.get_env(:code_my_spec, :device_config_path, @default_path)
    |> Path.expand()
  end

  # What this machine is, from how it authenticates rather than from what it
  # calls itself. A sprite is pinned to one project and holds a deploy key; a
  # laptop has a signed-in user. That answer already exists at connect time and
  # was being discarded — a hostname was carrying it, badly, inside a free-text
  # label.
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

  defp credential do
    case Token.access_token() do
      {:ok, token} -> {:ok, token}
      _ -> Config.credential()
    end
  end

  # Through the seam rather than straight at `Req`. Writing this as a direct
  # call produced a spec that POSTed to the live server with a valid token
  # attached — an unpinned Req plus a credential is a live call, every time.
  defp post(device_id, token) do
    Client.impl().announce(device_id, token, %{hostname: hostname(), kind: kind()})
  end

  # Merged over what is there rather than written fresh, so a field this version
  # does not know about survives a downgrade — the same rule `HarnessConfig.write/2`
  # follows for the per-checkout file.
  defp write(id) do
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
