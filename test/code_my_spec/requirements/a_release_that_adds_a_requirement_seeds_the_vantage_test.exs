defmodule CodeMySpec.Requirements.AReleaseThatAddsARequirementSeedsTheVantageTest do
  @moduledoc """
  A projector arriving trusts rows, and rows that predate a definition are
  not rows to trust.

  `questions_answered` shipped in v2.0.147. The next morning on dev not one
  of the big project's 138 stories had the row at any of its eleven vantages:
  the projector met every vantage with rows and trusted them, the handler for
  the new requirement settled rows that did not exist, and nothing seeds a
  vantage that has rows. The people answering questions were answering into
  a graph that had no requirement for it.

  So arrival compares names as well as presence. A vantage whose rows carry a
  requirement the templates no longer define, or lack one they do, is seeded
  like a vantage with none.
  """
  use CodeMySpecSpex.Case, async: true
  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphStore
  alias CodeMySpec.Requirements.IncrementalGraph
  alias CodeMySpec.StoriesFixtures
  alias CodeMySpec.Users.Scope

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok
  end

  describe "a projector arriving on rows written before a requirement existed" do
    test "seeds the vantage rather than trusting it", %{scope: %Scope{} = project_scope} do
      scope = %{project_scope | active_working_copy_id: nil}
      StoriesFixtures.story_fixture(scope)
      StoriesFixtures.story_fixture(scope)
      {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
      :ok = IncrementalGraph.settle(scope.active_project_id)

      stories = story_count(scope)
      assert rows_named(scope, "three_amigos_complete") == stories, "the premise did not hold"

      # The rows as a release before the definition would have left them.
      {deleted, _} =
        scope
        |> story_rows("three_amigos_complete")
        |> Repo.delete_all()

      assert deleted == stories

      restart_projector(scope)

      assert rows_named(scope, "three_amigos_complete") == stories,
             """
             A projector arrived on rows that lacked a requirement the template
             defines, trusted them, and left every story without it.

             Handlers settle rows and never create them, so a definition that
             ships after the rows were written can only arrive through a seed —
             and a seed only runs where arrival decides the rows are not to be
             trusted.
             """
    end

    test "seeds a vantage carrying a requirement no template defines any more",
         %{scope: %Scope{} = project_scope} do
      scope = %{project_scope | active_working_copy_id: nil}
      story = StoriesFixtures.story_fixture(scope)
      {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
      :ok = IncrementalGraph.settle(scope.active_project_id)

      # A row a retired definition left behind.
      [{template_row_id}] =
        scope
        |> story_rows("bdd_specs_exist")
        |> Ecto.Query.select([n], {n.id})
        |> Ecto.Query.limit(1)
        |> Repo.all()

      row =
        Repo.one!(
          from(n in "requirements",
            where: n.id == ^template_row_id,
            select:
              map(n, [
                :story_id,
                :description,
                :satisfied,
                :scope,
                :validation_type,
                :execution_type,
                :working_copy_id,
                :inserted_at,
                :updated_at,
                :checked_at
              ])
          )
        )

      Repo.insert_all("requirements", [
        Map.merge(row, %{name: "retired_requirement", story_id: story.id, satisfied_by: nil})
      ])

      assert rows_named(scope, "retired_requirement") == 1

      restart_projector(scope)

      assert rows_named(scope, "retired_requirement") == 0,
             "a row for a requirement no template defines survived the projector's arrival"
    end
  end

  describe "a projector arriving on edges drawn under an older template" do
    # A release that moves a prerequisite moves the edges and not one row, so
    # names cover and the rows are rightly trusted; the edges are redrawn once.
    test "redraws them", %{scope: %Scope{} = project_scope} do
      scope = %{project_scope | active_working_copy_id: nil}
      StoriesFixtures.story_fixture(scope)
      {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
      :ok = IncrementalGraph.settle(scope.active_project_id)

      drawn = story_edges(scope)
      assert drawn != [], "the premise did not hold: no story edges were drawn"

      # The edges as an older template would have drawn them: one absent, under
      # a hash this release's templates do not produce.
      project_id = scope.active_project_id
      older = GraphStore.edges(project_id) -- [hd(drawn)]
      :ok = GraphStore.write_topology(project_id, "an older template", older, older)
      assert length(story_edges(scope)) == length(drawn) - 1

      restart_projector(scope)

      assert story_edges(scope) == drawn,
             """
             A projector arrived on edges that did not match the templates it
             loaded, took the shape as its baseline, and left the edges as they
             were.

             Rows are trusted on arrival because the next observation about an
             entity corrects them. No observation moves an edge a release moved;
             only a redraw does.
             """
    end
  end

  defp story_edges(%Scope{active_project_id: project_id}) do
    project_id
    |> GraphStore.edges()
    |> Enum.filter(&match?(%{from: {"story", _, _}}, &1))
    |> Enum.sort()
  end

  defp restart_projector(%Scope{} = scope) do
    pid = GenServer.whereis(IncrementalGraph.via(scope.active_project_id))
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(CodeMySpec.Requirements.WatcherSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    {:ok, fresh} = IncrementalGraph.ensure_projecting(scope)
    refute fresh == pid, "the projector did not go away, so nothing arrived"
    :ok = IncrementalGraph.settle(scope.active_project_id)
  end

  defp story_count(%Scope{active_project_id: project_id}) do
    Repo.one(
      from(s in "stories",
        where: s.project_id == type(^project_id, :binary_id),
        select: count(s.id)
      )
    )
  end

  defp rows_named(%Scope{} = scope, name), do: scope |> story_rows(name) |> Repo.aggregate(:count)

  # Where the name's rows live: once per project, or per checkout.
  defp story_rows(scope, name),
    do: story_rows(scope, name, name in GraphStore.project_wide_names())

  defp story_rows(%Scope{active_project_id: project_id}, name, true) do
    from(n in "project_requirements",
      where: n.story_id in subquery(project_stories(project_id)) and n.name == ^name
    )
  end

  defp story_rows(
         %Scope{active_project_id: project_id, active_working_copy_id: copy},
         name,
         false
       ) do
    from(n in "requirements",
      where: n.story_id in subquery(project_stories(project_id)) and n.name == ^name,
      where: is_nil(n.working_copy_id) == is_nil(type(^copy, :binary_id))
    )
  end

  defp project_stories(project_id),
    do: from(s in "stories", where: s.project_id == type(^project_id, :binary_id), select: s.id)
end
