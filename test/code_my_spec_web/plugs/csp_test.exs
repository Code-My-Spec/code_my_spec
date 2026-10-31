defmodule CodeMySpecWeb.Plugs.CSPTest do
  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.{UsersFixtures, AccountsFixtures, ProjectsFixtures}

  alias CodeMySpecWeb.Plugs.CSP

  setup %{conn: conn} do
    user = user_fixture()
    account = account_fixture()
    member_fixture(user, account)
    scope = user_scope_fixture(user, account)

    %{conn: conn, scope: scope}
  end

  describe "call/2" do
    test "off a route with no :project_id, frame-src carries the built-in default", %{
      conn: conn
    } do
      header = header(CSP.call(conn, []))

      assert header =~ "https://accounts.google.com"
      assert header =~ "https://github.com"
    end

    test "on a project route, frame-src carries that project's own extra origins instead", %{
      conn: conn,
      scope: scope
    } do
      project =
        project_fixture(scope, preview_extra_frame_origins: ["gitlab.com"])

      header =
        conn
        |> Map.put(:path_params, %{"project_id" => project.id})
        |> CSP.call([])
        |> header()

      assert header =~ "https://gitlab.com"
      refute header =~ "https://accounts.google.com"
      refute header =~ "https://github.com"
    end

    test "an unknown project id falls back to the default rather than erroring", %{conn: conn} do
      header =
        conn
        |> Map.put(:path_params, %{"project_id" => Ecto.UUID.generate()})
        |> CSP.call([])
        |> header()

      assert header =~ "https://accounts.google.com"
      assert header =~ "https://github.com"
    end
  end

  defp header(conn) do
    conn |> Plug.Conn.get_resp_header("content-security-policy") |> List.first()
  end

  # Seen blocked in production on 2026-10-30: Clarity's script host, GA4's
  # collect endpoints, and the Google Signals audience pixel.
  test "admits the analytics hosts the tags actually use", %{conn: conn} do
    header = header(CSP.call(conn, []))

    directive = fn name ->
      header |> String.split("; ") |> Enum.find(&String.starts_with?(&1, name))
    end

    assert directive.("script-src") =~ "https://*.clarity.ms"
    assert directive.("connect-src") =~ "https://*.analytics.google.com"
    assert directive.("connect-src") =~ "https://*.google-analytics.com"
    assert directive.("connect-src") =~ "https://www.google.com"
    assert directive.("img-src") =~ "https://www.google.ca"
  end
end
