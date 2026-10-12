defmodule CodeMySpec.Integrations.DesktopClientsTest do
  @moduledoc """
  The desktop connects integrations with clients made for an app that keeps no
  server secret, each redirecting to this machine (bb8bc042).
  """
  # Not async: writes app env and CMS_PROJECT_DIR, both process-global.
  use ExUnit.Case, async: false

  alias CodeMySpec.Integrations
  alias CodeMySpec.Integrations.DesktopClients

  setup do
    dir = Path.join(System.tmp_dir!(), "oauth_clients_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "project"))
    previous_dir = System.get_env("CMS_PROJECT_DIR")
    previous_clients = Application.get_env(:code_my_spec, :desktop_oauth_clients)
    previous_overrides = Application.get_env(:code_my_spec, :integration_client_overrides)

    # local_state_dir/0 is CMS_PROJECT_DIR's parent: resend_client.json lands in `dir`.
    System.put_env("CMS_PROJECT_DIR", Path.join(dir, "project"))

    Application.put_env(:code_my_spec, :desktop_oauth_clients,
      google_client_id: "desktop-google-id",
      google_client_secret: "desktop-google-secret",
      cloudflare_client_id: "public-cloudflare-id"
    )

    on_exit(fn ->
      restore_env("CMS_PROJECT_DIR", previous_dir)
      restore_config(:desktop_oauth_clients, previous_clients)
      restore_config(:integration_client_overrides, previous_overrides)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
  defp restore_config(key, nil), do: Application.delete_env(:code_my_spec, key)
  defp restore_config(key, value), do: Application.put_env(:code_my_spec, key, value)

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp stub_registration(client_id) do
    test = self()

    Req.Test.stub(DesktopClients, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:registered, Jason.decode!(body)})
      Req.Test.json(Plug.Conn.put_status(conn, 201), %{"client_id" => client_id})
    end)
  end

  test "Cloudflare connects with the public client and a loopback redirect" do
    :ok = DesktopClients.configure()

    {:ok, %{url: url}} = Integrations.authorize_url(:cloudflare)
    params = query(url)

    assert params["client_id"] == "public-cloudflare-id"
    assert params["redirect_uri"] == DesktopClients.redirect_uri()
    assert params["redirect_uri"] =~ ~r"^http://127\.0\.0\.1:\d+/callback$"
  end

  test "Google connects with the desktop-app client" do
    # Google's strategy reads its OIDC discovery document first.
    Req.Test.stub(Assent, fn conn ->
      Req.Test.json(conn, %{
        "issuer" => "https://accounts.google.com",
        "authorization_endpoint" => "https://accounts.google.com/o/oauth2/v2/auth",
        "token_endpoint" => "https://oauth2.googleapis.com/token",
        "jwks_uri" => "https://www.googleapis.com/oauth2/v3/certs"
      })
    end)

    :ok = DesktopClients.configure()

    {:ok, %{url: url}} = Integrations.authorize_url(:google)

    assert query(url)["client_id"] == "desktop-google-id"
    assert query(url)["redirect_uri"] == DesktopClients.redirect_uri()
  end

  test "Resend registers this install's public client once, then reuses it", %{dir: dir} do
    stub_registration("install-client")

    assert {:ok, "install-client"} = DesktopClients.ensure_resend()

    assert_received {:registered,
                     %{"token_endpoint_auth_method" => "none", "redirect_uris" => [uri]}}

    assert uri == DesktopClients.redirect_uri()
    assert File.exists?(Path.join(dir, "resend_client.json"))

    assert {:ok, "install-client"} = DesktopClients.ensure_resend()
    refute_received {:registered, _}

    {:ok, %{url: url}} = Integrations.authorize_url(:resend)
    assert query(url)["client_id"] == "install-client"
  end

  test "a changed redirect (another PORT) registers a new client", %{dir: dir} do
    File.write!(
      Path.join(dir, "resend_client.json"),
      Jason.encode!(%{client_id: "old", redirect_uri: "http://127.0.0.1:1/callback"})
    )

    stub_registration("new-client")

    assert {:ok, "new-client"} = DesktopClients.ensure_resend()
    assert_received {:registered, _}
  end
end
