defmodule CodeMySpec.Requirements.GraphStoreSkipsUnchangedWritesTest do
  @moduledoc """
  181f3469: a row EXCLUDED agrees with on every stored column is left alone,
  not rewritten -- proved here on the real table by backdating every row's
  `updated_at` first: a row the write rewrote is stamped again, one it left
  alone keeps the old stamp. `satisfied`/`details` staying equal is not by
  itself evidence that nothing was written.

  A row the write still covers but does not touch must not read as reaped
  either -- that is the trap a naive `RETURNING`-only diff falls into, and
  what `a_config_dropped_definition_is_reaped_test.exs` guards from the other
  side (a row genuinely gone IS reaped).
  """

  use CodeMySpecTest.DataCase, async: true

  import Ecto.Query
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphStore
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.RequirementGraph

  setup do
    scope = full_scope_fixture()
    story = story_fixture(scope, %{ready_for_dev: true})
    %{scope: scope, story: story}
  end

  test "an unchanged row is not rewritten, and still is not reaped", ctx do
    {:ok, _} = event_write(ctx.scope, ctx.story)
    backdate(ctx.story.id)
    before_versions = row_versions(ctx.story.id)
    assert map_size(before_versions) > 0

    {:ok, %{inserted: inserted, reaped: reaped}} = event_write(ctx.scope, ctx.story)

    assert inserted == 0, "nothing is new on a second write with nothing changed"
    assert reaped == 0, "a row this write still covers must not read as reaped"

    assert row_versions(ctx.story.id) == before_versions,
           "a row was stamped again, so it was rewritten even though nothing about it changed"
  end

  test "a row that did change is rewritten; its unchanged siblings are not", ctx do
    {:ok, _} = event_write(ctx.scope, ctx.story)
    backdate(ctx.story.id)
    before_versions = row_versions(ctx.story.id)

    set_devops(ctx.scope, :prod)
    {:ok, %{reaped: reaped}} = event_write(ctx.scope, ctx.story)
    assert reaped == 0

    after_versions = row_versions(ctx.story.id)

    changed =
      for {name, stamp} <- after_versions, Map.get(before_versions, name) != stamp, do: name

    assert changed != [], "devops going from unset to :prod has to change at least one row"

    unchanged = Map.keys(before_versions) -- changed

    for name <- unchanged do
      assert Map.fetch!(after_versions, name) == Map.fetch!(before_versions, name),
             "#{name} did not depend on devops and should not have been rewritten"
    end
  end

  test "write counts include only inserted or changed rows", ctx do
    {:ok, loaded} = Preloader.load(ctx.scope)
    config = Configurations.get_or_create(ctx.scope)

    {covered, nodes} =
      RequirementGraph.compute_entity(ctx.scope, loaded, config, {"story", ctx.story.id})

    [first, second | rest] = nodes
    {:ok, _} = GraphStore.write(ctx.scope, covered, nodes)

    {unchanged, unchanged_cost} = measured_write(ctx.scope, covered, nodes)
    assert unchanged == {:ok, %{inserted: 0, reaped: 0}}
    assert unchanged_cost.rows_written == 0
    refute unchanged_cost.raised

    first = %{first | satisfied: not first.satisfied}
    second = %{second | details: %{"reason" => "changed write-count probe"}}
    changed_nodes = [first, second | rest]

    {changed, changed_cost} = measured_write(ctx.scope, covered, changed_nodes)
    assert changed == {:ok, %{inserted: 0, reaped: 0}}
    assert changed_cost.rows_written == 2
    refute changed_cost.raised

    stored =
      from(n in subquery(GraphStore.project_rows()))
      |> where([n], n.story_id == ^ctx.story.id)
      |> select([n], {n.name, %{satisfied: n.satisfied, details: n.details}})
      |> Repo.all()
      |> Map.new()

    assert Map.fetch!(stored, first.name).satisfied == first.satisfied
    assert Map.fetch!(stored, second.name).details == second.details

    {repeated, repeated_cost} = measured_write(ctx.scope, covered, changed_nodes)
    assert repeated == {:ok, %{inserted: 0, reaped: 0}}
    assert repeated_cost.rows_written == 0
    refute repeated_cost.raised
  end

  defp measured_write(scope, covered, nodes) do
    # A separate report key prevents background drains from replacing this measurement.
    measurement_id = Ecto.UUID.generate()

    result =
      CodeMySpec.Requirements.DrainCost.measure(
        %{kind: :event, project_id: measurement_id},
        fn -> {GraphStore.write(scope, covered, nodes), %{}} end
      )

    {result, CodeMySpec.Requirements.DrainCost.last(measurement_id, :event)}
  end

  defp event_write(scope, story) do
    {:ok, loaded} = Preloader.load(scope)
    config = Configurations.get_or_create(scope)
    {covered, nodes} = RequirementGraph.compute_entity(scope, loaded, config, {"story", story.id})
    GraphStore.write(scope, covered, nodes)
  end

  defp set_devops(scope, level) do
    Configurations.get_or_create(scope)

    ProjectConfiguration
    |> where([c], c.project_id == ^scope.active_project_id)
    |> Repo.update_all(set: [devops: level])
  end

  defp backdate(story_id) do
    {"project_requirements", CodeMySpec.Requirements.Node}
    |> where([n], n.story_id == ^story_id)
    |> Repo.update_all(set: [updated_at: ~N[2000-01-01 00:00:00]])
  end

  defp row_versions(story_id) do
    {"project_requirements", CodeMySpec.Requirements.Node}
    |> where([n], n.story_id == ^story_id)
    |> select([n], {n.name, n.updated_at})
    |> Repo.all()
    |> Map.new()
  end
end
