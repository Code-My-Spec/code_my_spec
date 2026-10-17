defmodule CodeMySpec.McpServers.Bootstrap.Tools.ListProjectsTest do
  @moduledoc """
  list_projects round-trips the server's own /api/projects rather than
  querying this database, so it is the one tool in 8f26f7ba tested against a
  stubbed Req.Test plug instead of an Ecto fixture.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.McpServers.Bootstrap.Tools.ListProjects

  setup do
    %{frame: %Frame{assigns: %{current_scope: nil}}}
  end

  test "script_result returns the server's projects as rows, not prose", %{frame: frame} do
    user = user_fixture()

    {:ok, _client_user} =
      OAuthClient.save_client_user(user.id, user.email, %{
        "access_token" => "test-access-token",
        "refresh_token" => "test-refresh-token",
        "expires_in" => 3600
      })

    Req.Test.stub(ListProjects, fn conn ->
      Req.Test.json(conn, %{"projects" => [%{"id" => "proj-1", "name" => "Demo"}]})
    end)

    assert {:ok, [%{"id" => "proj-1", "name" => "Demo"}]} = ListProjects.script_result(%{}, frame)
  end

  test "script_result reports the refusal rather than a table when nobody is authenticated", %{
    frame: frame
  } do
    assert {:error, _reason} = ListProjects.script_result(%{}, frame)
  end
end
