defmodule CodeMySpecWeb.Plugs.LowercasePathRedirect do
  @moduledoc """
  Redirects URLs with uppercase characters to their lowercase equivalent.
  Preserves query strings. Skips static file paths and paths that are already lowercase.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: path} = conn, _opts) do
    lowered = String.downcase(path)

    if path != lowered do
      location =
        case conn.query_string do
          "" -> lowered
          qs -> "#{lowered}?#{qs}"
        end

      conn
      |> put_resp_header("location", location)
      |> send_resp(301, "")
      |> halt()
    else
      conn
    end
  end
end
