defmodule CodeMySpecDesktop.Application.SetupPlug do
  @moduledoc "Loopback-only, per-launch access to database-free desktop setup."
  @behaviour Plug

  import Plug.Conn
  alias CodeMySpecDesktop.Application.{Bootstrap, SetupPage}

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, opts) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "same-origin")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header(
        "content-security-policy",
        "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
      )

    dispatch(conn, opts, loopback?(conn.remote_ip))
  end

  defp dispatch(conn, _opts, false), do: send_resp(conn, 403, "Local access only")

  defp dispatch(
         %{method: "GET", path_info: ["setup", token]} = conn,
         %{token: token} = opts,
         true
       ) do
    html = SetupPage.render(Bootstrap.status(opts.bootstrap), "/setup/" <> token, opts.app_url)
    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  defp dispatch(
         %{method: "POST", path_info: ["setup", token, action]} = conn,
         %{token: token} = opts,
         true
       )
       when action in ["check", "continue"] do
    perform(conn, opts, action, same_origin?(conn))
  end

  defp dispatch(conn, _opts, true), do: send_resp(conn, 404, "Not found")

  defp perform(conn, _opts, _action, false), do: send_resp(conn, 403, "Invalid origin")

  defp perform(conn, opts, action, true) do
    respond(conn, opts.token, invoke(action, opts.bootstrap))
  end

  defp invoke("check", server), do: Bootstrap.check(server)
  defp invoke("continue", server), do: Bootstrap.continue(server)

  defp respond(conn, token, :ok), do: redirect(conn, token)
  defp respond(conn, token, {:error, :busy}), do: redirect(conn, token)
  defp respond(conn, token, {:error, :already_started}), do: redirect(conn, token)

  defp respond(conn, _token, {:error, :prerequisites_failed}),
    do: send_resp(conn, 409, "Prerequisite checks must pass before starting CodeMySpec")

  defp redirect(conn, token) do
    conn |> put_resp_header("location", "/setup/" <> token) |> send_resp(303, "")
  end

  defp same_origin?(conn) do
    expected =
      URI.to_string(%URI{scheme: to_string(conn.scheme), host: conn.host, port: conn.port})

    case get_req_header(conn, "origin") do
      [] -> true
      [^expected] -> true
      _ -> false
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_address), do: false
end
