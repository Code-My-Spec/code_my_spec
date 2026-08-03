defmodule CodeMySpecWeb.IssuesLive.IndexTest do
  @moduledoc """
  These tests followed the local issues index into `CodeMySpecWeb`, where the
  surviving view is the cloud one. Its filter model is different: string
  assigns defaulting to "all" rather than a map of atoms, so the assertions
  moved to that contract because the view they described no longer exists.

  Scope filtering is asserted here because the merge dropped it — the local
  index had it, the cloud one did not — and it has since been put back. That
  test is the record of a capability the move nearly cost silently.

  What did survive is the property worth keeping: filters live in the query
  string, so a filtered list is a link you can send someone and it survives a
  reload. `handle_event("filter", ...)` is a thin push_patch wrapper that
  re-enters through `handle_params`, so driving `handle_params` with the param
  shape the router produces is the honest test.

  The project itself comes from `PortableHost` now, not from a `project_name`
  param, so these build the socket the host would have handed over.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpecWeb.IssuesLive.Index
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "handle_params filter parsing" do
    test "a severity in the query string narrows the result set" do
      {project, scope} = setup_local_project()

      issue_fixture(scope, %{title: "match", severity: :high})
      issue_fixture(scope, %{title: "wrong severity", severity: :low})

      socket = build_socket(project, scope)
      {:noreply, socket} = Index.handle_params(%{"severity" => "high"}, "/", socket)

      assert socket.assigns.filter_severity == "high"
      assert Enum.map(socket.assigns.issues, & &1.title) == ["match"]
    end

    test "status and severity combine" do
      {project, scope} = setup_local_project()

      issue_fixture(scope, %{title: "match", severity: :high, status: :accepted})
      issue_fixture(scope, %{title: "wrong status", severity: :high, status: :incoming})

      socket = build_socket(project, scope)

      {:noreply, socket} =
        Index.handle_params(%{"status" => "accepted", "severity" => "high"}, "/", socket)

      assert socket.assigns.filter_status == "accepted"
      assert socket.assigns.filter_severity == "high"
      assert Enum.map(socket.assigns.issues, & &1.title) == ["match"]
    end

    test "a value outside the allowed set falls back rather than querying it" do
      {project, scope} = setup_local_project()
      issue_fixture(scope, %{title: "kept", severity: :high})

      socket = build_socket(project, scope)

      {:noreply, socket} =
        Index.handle_params(%{"status" => "", "severity" => "bogus"}, "/", socket)

      assert socket.assigns.filter_status == "all"
      assert socket.assigns.filter_severity == "all"
      assert Enum.map(socket.assigns.issues, & &1.title) == ["kept"]
    end

    test "scope is filterable again, as it was on the local index" do
      {project, scope} = setup_local_project()

      issue_fixture(scope, %{title: "qa issue", scope: :qa})
      issue_fixture(scope, %{title: "app issue", scope: :app})

      socket = build_socket(project, scope)
      {:noreply, socket} = Index.handle_params(%{"scope" => "qa"}, "/", socket)

      assert socket.assigns.filter_scope == "qa"
      assert Enum.map(socket.assigns.issues, & &1.title) == ["qa issue"]
    end

    test "empty params leave both filters at all" do
      {project, scope} = setup_local_project()

      socket = build_socket(project, scope)
      {:noreply, socket} = Index.handle_params(%{}, "/", socket)

      assert socket.assigns.filter_status == "all"
      assert socket.assigns.filter_severity == "all"
      assert socket.assigns.filter_scope == "all"
    end

    test "does nothing until the host has resolved a scope" do
      socket = build_socket(nil, nil)

      assert {:noreply, ^socket} = Index.handle_params(%{}, "/", socket)
    end
  end

  describe "handle_event \"filter\"" do
    # `handle_event` push_patches to a filter URL — handle_params then picks up
    # the params on the round-trip. We can't observe the patch destination from
    # a raw socket struct (no transport), so the round-trip itself is covered
    # above. Here we just confirm the handler tolerates the param shapes the
    # form emits, blanks included, without raising.
    test "tolerates the form's full param shape including blanks" do
      {project, scope} = setup_local_project()
      socket = build_socket(project, scope)

      assert {:noreply, _socket} =
               Index.handle_event(
                 "filter",
                 %{"status" => "", "severity" => "high", "scope" => "qa"},
                 socket
               )

      assert {:noreply, _socket} =
               Index.handle_event(
                 "filter",
                 %{"status" => "", "severity" => "", "scope" => ""},
                 socket
               )
    end
  end

  describe "render" do
    test "wraps the filter selects in a form so phx-change fires" do
      {project, scope} = setup_local_project()
      socket = build_socket(project, scope)
      {:noreply, socket} = Index.handle_params(%{}, "/", socket)

      html = Phoenix.LiveViewTest.rendered_to_string(Index.render(socket.assigns))

      assert html =~ ~r/<form[^>]+phx-change="filter"/,
             ~s(expected the filter selects to be wrapped in a <form phx-change="filter"> so events fire on bare-select change)
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

  # Mirrors what PortableHost leaves on the socket before handle_params runs —
  # including `current_scope`, which is what this view actually queries with.
  defp build_socket(project, scope) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        live_action: :index,
        projects: [project],
        project: project,
        scope: scope,
        current_scope: scope,
        slug: project && project.id,
        section: :issues,
        page_title: "Issues",
        issues: [],
        filter_status: "all",
        filter_severity: "all",
        filter_scope: "all",
        status_options: ~w(all incoming accepted dismissed resolved),
        severity_options: ~w(all critical high medium low info),
        scope_options: ~w(all app qa docs framework),
        error: nil,
        flash: %{}
      },
      endpoint: CodeMySpecWeb.Endpoint
    }
  end
end
