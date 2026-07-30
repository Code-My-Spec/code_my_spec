defmodule CodeMySpec.McpServers.ServerMountedScopeTest do
  @moduledoc """
  The harness tools, resolved the way the server resolves them.

  Every tool funnels through `Validators.validate_local_scope/2`, which today
  resolves a project by handing a working directory to a database lookup. A
  server has no working directory, so what these assert is the other branch:
  given a scope that already names a project — the one
  `require_oauth_token` + `ProjectScopeOverride` build from an `X-Project-ID`
  header — the tools work with no filesystem in the picture at all.
  """

  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Validators

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
    %{scope: full_scope_fixture()}
  end

  describe "scope resolution without a working directory" do
    test "a frame carrying a project-scoped session resolves with no working dir",
         %{scope: scope} do
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:ok, resolved} = Validators.validate_local_scope(frame)
      assert resolved.active_project_id == scope.active_project_id
    end

    test "a frame with neither a project nor a working dir is refused, not guessed at" do
      frame = %Frame{assigns: %{}}

      # The important half. On the local mount this would fall through to a
      # `local_path` lookup; here there is nothing to look up and nothing to
      # guess from, and the tools must say so rather than resolve to whichever
      # project happened to be updated most recently.
      assert {:error, reason} = Validators.validate_local_scope(frame)
      assert reason in [:no_working_dir, :unauthorized]
    end

    test "a scope whose project is nil does not silently pass through" do
      user = user_fixture()
      scope = CodeMySpec.Users.Scope.for_user(user)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:error, _} = Validators.validate_local_scope(frame)
    end
  end

  describe "a pure-DB tool over a server-shaped frame" do
    test "list_story_titles answers from a project-scoped frame alone", %{scope: scope} do
      alias CodeMySpec.McpServers.Stories.Tools.{CreateStory, ListStoryTitles}

      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, create_response, _} =
        CreateStory.execute(
          %{
            title: "Watch a sprite from the server",
            story: "As an operator, I want to see what a sprite is doing."
          },
          frame
        )

      refute create_response.isError,
             inspect(Anubis.Server.Response.to_protocol(create_response))

      {:reply, list_response, _} = ListStoryTitles.execute(%{}, frame)

      refute list_response.isError

      text = list_response |> Anubis.Server.Response.to_protocol() |> get_in(["content"]) |> hd()

      assert text["text"] =~ "Watch a sprite from the server",
             "a story tool must round-trip with no working directory anywhere in the frame"
    end
  end
end
