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

  The project itself comes from `UserAuth.on_mount(:assign_project, ...)`, not
  from a `project_name` param, so these build the socket that hook hands over.
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
      {:noreply, socket} = Index.handle_params(%{"severity" => ["high"]}, "/", socket)

      assert socket.assigns.filter_severity == ["high"]
      assert Enum.map(socket.assigns.issues, & &1.title) == ["match"]
    end

    test "status and severity combine" do
      {project, scope} = setup_local_project()

      issue_fixture(scope, %{title: "match", severity: :high, status: :accepted})
      issue_fixture(scope, %{title: "wrong status", severity: :high, status: :incoming})

      socket = build_socket(project, scope)

      {:noreply, socket} =
        Index.handle_params(%{"status" => ["accepted"], "severity" => ["high"]}, "/", socket)

      assert socket.assigns.filter_status == ["accepted"]
      assert socket.assigns.filter_severity == ["high"]
      assert Enum.map(socket.assigns.issues, & &1.title) == ["match"]
    end

    test "a value outside the allowed set falls back rather than querying it" do
      {project, scope} = setup_local_project()
      issue_fixture(scope, %{title: "kept", severity: :high})

      socket = build_socket(project, scope)

      {:noreply, socket} =
        Index.handle_params(%{"status" => "", "severity" => "bogus"}, "/", socket)

      assert socket.assigns.filter_status == ~w(incoming accepted)
      assert socket.assigns.filter_severity == ~w(high medium)
      assert Enum.map(socket.assigns.issues, & &1.title) == ["kept"]
    end

    test "severity is a set, high and medium unless asked otherwise" do
      {project, scope} = setup_local_project()

      for {title, severity} <- [
            {"crit", :critical},
            {"high", :high},
            {"med", :medium},
            {"low", :low}
          ],
          do: issue_fixture(scope, %{title: title, severity: severity})

      socket = build_socket(project, scope)
      {:noreply, socket} = Index.handle_params(%{}, "/", socket)
      assert socket.assigns.issues |> Enum.map(& &1.title) |> Enum.sort() == ["high", "med"]

      {:noreply, socket} =
        Index.handle_params(%{"severity" => ["critical", "low"]}, "/", socket)

      assert socket.assigns.issues |> Enum.map(& &1.title) |> Enum.sort() == ["crit", "low"]

      {:noreply, socket} = Index.handle_params(%{"severity" => "none"}, "/", socket)
      assert socket.assigns.issues == []
    end

    test "sorts by what is asked, newest by default" do
      require Ecto.Query
      {project, scope} = setup_local_project()
      old = issue_fixture(scope, %{title: "old", severity: :medium})
      new = issue_fixture(scope, %{title: "new", severity: :high})

      CodeMySpec.Repo.update_all(
        Ecto.Query.where(CodeMySpec.Issues.Issue, id: ^old.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      socket = build_socket(project, scope)
      {:noreply, socket} = Index.handle_params(%{}, "/", socket)
      assert Enum.map(socket.assigns.issues, & &1.id) == [new.id, old.id]

      {:noreply, socket} = Index.handle_params(%{"sort" => "oldest"}, "/", socket)
      assert Enum.map(socket.assigns.issues, & &1.id) == [old.id, new.id]
    end

    test "pages fifty at a time" do
      {project, scope} = setup_local_project()
      for i <- 1..55, do: issue_fixture(scope, %{title: "issue #{i}", severity: :high})

      socket = build_socket(project, scope)
      {:noreply, socket} = Index.handle_params(%{}, "/", socket)
      assert length(socket.assigns.issues) == 50

      assert {socket.assigns.page, socket.assigns.total_pages, socket.assigns.total_count} ==
               {1, 2, 55}

      {:noreply, socket} = Index.handle_params(%{"page" => "2"}, "/", socket)
      assert length(socket.assigns.issues) == 5
    end

    test "a filter left out of the URL goes back to its default" do
      {project, scope} = setup_local_project()
      socket = build_socket(project, scope)

      {:noreply, socket} = Index.handle_params(%{"range" => "7d"}, "/", socket)
      assert socket.assigns.range == "7d"

      {:noreply, socket} = Index.handle_params(%{}, "/", socket)
      assert socket.assigns.range == "30d"
    end

    test "scope is filterable again, as it was on the local index" do
      {project, scope} = setup_local_project()

      issue_fixture(scope, %{title: "qa issue", scope: :qa})
      issue_fixture(scope, %{title: "app issue", scope: :app})

      socket = build_socket(project, scope)
      {:noreply, socket} = Index.handle_params(%{"scope" => "qa"}, "/", socket)

      assert socket.assigns.filter_scope == ["qa"]
      assert Enum.map(socket.assigns.issues, & &1.title) == ["qa issue"]
    end

    test "empty params default to open issues, high and medium, the app's" do
      {project, scope} = setup_local_project()

      socket = build_socket(project, scope)
      {:noreply, socket} = Index.handle_params(%{}, "/", socket)

      assert socket.assigns.filter_status == ~w(incoming accepted)
      assert socket.assigns.filter_severity == ~w(high medium)
      assert socket.assigns.filter_scope == ["app"]
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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  describe "labelling an issue's story" do
    # A story carries an id and a number, and the number is the one that names
    # its spex directory — id 1031 is number 1065, whose specs live in
    # `test/spex/1065_…/`. They coincide on a young project and diverge later,
    # which is how the id survived in the places people read for months
    # (1ab62ffd). John: "We should name the story from the number, not the id."
    #
    # Asserted through the assign rather than the rendered markup, which is what
    # this view's other tests do — `handle_params` is the seam here.
    test "the view is given the number for each story, not the id" do
      {project, scope} = setup_local_project()

      story = CodeMySpec.StoriesFixtures.story_fixture(scope)

      issue_fixture(scope, %{title: "against a story", story_id: story.id})

      socket = build_socket(project, scope)
      {:noreply, socket} = Index.handle_params(%{}, "/", socket)

      assert socket.assigns.story_numbers[story.id] == story.number,
             "the issues list labels a story `Story #<n>`; taking that from the id " <>
               "names a spex directory that does not exist"
    end

    test "a project's numbers are all present, so no issue renders a blank story" do
      {project, scope} = setup_local_project()

      first = CodeMySpec.StoriesFixtures.story_fixture(scope)
      second = CodeMySpec.StoriesFixtures.story_fixture(scope)

      socket = build_socket(project, scope)
      {:noreply, socket} = Index.handle_params(%{}, "/", socket)

      for story <- [first, second] do
        assert is_integer(socket.assigns.story_numbers[story.id])
      end
    end
  end

  defp setup_local_project do
    scope = full_scope_fixture()
    project = scope.active_project

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, project, %{local_path: "/tmp/test-project"})

    scope = %{scope | active_project: project}
    {project, scope}
  end

  # Mirrors what `UserAuth.on_mount(:assign_project, ...)` leaves on the socket.
  defp build_socket(project, scope) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        live_action: :index,
        projects: [project],
        project: project,
        current_scope: scope,
        current_path: "/",
        section: :issues,
        page_title: "Issues",
        issues: [],
        filter_status: ~w(incoming accepted),
        filter_severity: ~w(high medium),
        range: "30d",
        chart: "status",
        sort: "newest",
        page: 1,
        filter_scope: ~w(app qa docs framework),
        status_options: ~w(incoming accepted resolved dismissed),
        severity_options: ~w(critical high medium low info),
        scope_options: ~w(app qa docs framework),
        sort_options: ~w(newest oldest updated severity),
        total_pages: 1,
        total_count: 0,
        chart_issues: [],
        error: nil,
        flash: %{}
      },
      endpoint: CodeMySpecWeb.Endpoint
    }
  end
end
