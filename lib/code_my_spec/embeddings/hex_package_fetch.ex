defmodule CodeMySpec.Embeddings.HexPackageFetch do
  @moduledoc """
  Fetches one `package@version`'s tarball from hex.pm and verifies it
  against the checksum `mix.lock` itself pinned.

  The one place a request to hex.pm is built, same reasoning as
  `Research.Http`: a `Req.Test` plug attached here is attached everywhere
  this is called from, so an async test stubs real tarball bytes rather
  than hitting the network.
  """

  require Logger

  @default_timeout to_timeout(second: 30)
  @connect_timeout to_timeout(second: 10)

  @doc """
  `{:ok, tarball_bytes}` once fetched and checksum-verified, or
  `{:error, reason}`. `checksum` is `project_dependencies.checksum` —
  hex.pm's own sha256 of the outer tarball, upper-hex as `mix.lock` records
  it. A `nil` checksum (a lock written before the checksum column existed)
  is refused rather than trusted blind.
  """
  @spec fetch(String.t(), String.t(), String.t() | nil) ::
          {:ok, binary()} | {:error, term()}
  def fetch(_package, _version, nil), do: {:error, :no_checksum}

  def fetch(package, version, checksum) when is_binary(package) and is_binary(version) do
    with {:ok, body} <- get_tarball(package, version) do
      verify_checksum(body, checksum)
    end
  end

  defp get_tarball(package, version) do
    url = "https://repo.hex.pm/tarballs/#{package}-#{version}.tar"

    # Explicit bounds on both halves of the request, not just
    # `receive_timeout`: a connection that never completes its handshake
    # is a different hang than one that completes and then goes quiet,
    # and `Req`'s own connect default was long enough to leave a sweep
    # looking frozen rather than failed.
    req =
      [
        url: url,
        connect_options: [timeout: @connect_timeout],
        receive_timeout: @default_timeout,
        retry: false
      ]
      |> Req.new()
      |> attach_plug()

    case Req.get(req) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_checksum(body, checksum) do
    actual = :crypto.hash(:sha256, body) |> Base.encode16(case: :upper)

    if actual == String.upcase(checksum) do
      {:ok, body}
    else
      {:error, :checksum_mismatch}
    end
  end

  defp attach_plug(req) do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:plug] do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end
end
