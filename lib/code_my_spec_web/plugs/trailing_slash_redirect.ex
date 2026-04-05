defmodule CodeMySpecWeb.Plugs.TrailingSlashRedirect do
  @moduledoc """
  Redirects URLs with trailing slashes to their non-trailing-slash equivalent.
  Excludes the root path "/".
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/" <> _rest = path} = conn, _opts) do
    if path != "/" and String.ends_with?(path, "/") do
      trimmed = String.trim_trailing(path, "/")

      conn
      |> put_resp_header("location", trimmed)
      |> send_resp(301, "")
      |> halt()
    else
      conn
    end
  end
end
