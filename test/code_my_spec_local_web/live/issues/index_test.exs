defmodule CodeMySpecLocalWeb.IssuesLive.IndexTest do
  use ExUnit.Case, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpecLocalWeb.IssuesLive.Index
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "handle_event \"filter\"" do
    test "combining filters narrows the result set" do
      {project, scope} = setup_local_project()

      issue_fixture(scope, %{title: "match", severity: :high, scope: :app})
      issue_fixture(scope, %{title: "wrong severity", severity: :low, scope: :app})
      issue_fixture(scope, %{title: "wrong scope", severity: :high, scope: :qa})

      socket = build_socket(project, scope)

      {:noreply, socket} =
        Index.handle_event(
          "filter",
          %{"status" => "", "severity" => "high", "scope" => "app"},
          socket
        )

      titles = Enum.map(socket.assigns.issues, & &1.title)

      assert socket.assigns.filters == %{severity: :high, scope: :app}
      assert titles == ["match"]
    end

    test "selecting the blank option clears just that filter" do
      {project, scope} = setup_local_project()
      socket = build_socket(project, scope)

      {:noreply, socket} =
        Index.handle_event(
          "filter",
          %{"status" => "accepted", "severity" => "high", "scope" => ""},
          socket
        )

      assert socket.assigns.filters == %{status: :accepted, severity: :high}

      # User picks "All severities" — every other select keeps reporting its value
      # because phx-change fires on the enclosing form.
      {:noreply, socket} =
        Index.handle_event(
          "filter",
          %{"status" => "accepted", "severity" => "", "scope" => ""},
          socket
        )

      assert socket.assigns.filters == %{status: :accepted}
    end

    test "empty params yield no filters" do
      {project, scope} = setup_local_project()
      socket = build_socket(project, scope)

      {:noreply, socket} =
        Index.handle_event(
          "filter",
          %{"status" => "", "severity" => "", "scope" => ""},
          socket
        )

      assert socket.assigns.filters == %{}
    end
  end

  describe "render" do
    test "wraps the filter selects in a form so phx-change fires" do
      {project, scope} = setup_local_project()
      socket = build_socket(project, scope)
      {:noreply, socket} = Index.handle_params(%{"project_name" => project.name}, "/", socket)

      html = Phoenix.LiveViewTest.rendered_to_string(Index.render(socket.assigns))

      assert html =~ ~r/<form[^>]+phx-change="filter"/,
             ~s(expected the three filter selects to be wrapped in a <form phx-change="filter"> so events fire on bare-select change)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_local_project do
    scope = full_scope_fixture()
    project = scope.active_project

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, project, %{local_path: "/tmp/test-project"})

    scope = %{scope | active_project: project}
    {project, scope}
  end

  defp build_socket(project, scope) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        live_action: :index,
        projects: [project],
        project: project,
        scope: scope,
        slug: "test-project",
        issues: [],
        filters: %{},
        error: nil,
        flash: %{}
      },
      endpoint: CodeMySpecLocalWeb.Endpoint
    }
  end
end
