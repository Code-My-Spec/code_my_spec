defmodule CodeMySpec.AgentHarness.Secret do
  @moduledoc """
  Machine-local shared secret for the harness data-plane socket.

  Under the two-plane design the offsite/paid Pi harness authenticates to the
  **local** cms with this secret — never with the user's server OAuth token,
  which stays on the machine (local cms uses its own OAuth to reach the server).
  The `LocalOnly` IP check is not enough: the local endpoint can be exposed over
  a Cloudflare tunnel (dev_cli), through which every request looks like
  localhost. This secret is the real gate.

  Generated once and persisted `0600` under `~/.codemyspec/harness_secret`; the
  harness presents it as the socket `token` param (set `CMS_TOKEN` to its
  contents). A static override (`config :code_my_spec, :harness_secret, "..."`)
  skips file I/O — used in tests and by deployments that inject it out of band.
  """
  require Logger

  @default_path "~/.codemyspec/harness_secret"

  @doc "Validate a presented token against the machine secret (constant-time)."
  @spec valid?(term()) :: boolean()
  def valid?(presented) when is_binary(presented) and presented != "" do
    Plug.Crypto.secure_compare(presented, get_or_create())
  end

  def valid?(_presented), do: false

  @doc "The machine secret, generating + persisting it on first use."
  @spec get_or_create() :: String.t()
  def get_or_create do
    case Application.get_env(:code_my_spec, :harness_secret) do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> from_file()
    end
  end

  defp from_file do
    path = Path.expand(Application.get_env(:code_my_spec, :harness_secret_path, @default_path))

    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      {:error, _} -> generate_and_write(path)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp generate_and_write(path) do
    secret = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, secret)
    File.chmod(path, 0o600)
    Logger.info("[AgentHarness] generated harness socket secret at #{path}")
    secret
  end
end
