defmodule CodeMySpec.Requirements.ADiscoveryReadDoesNotScaleWithTheCheckoutsFilesTest do
  @moduledoc """
  A discovery read loads the shape it reads rows with, never the computation's
  preload. See knowledge/requirements_graph, "The read path".

  Discovery used to load `Preloader.load/2` twice per read -- every file row on
  the checkout, about 5,000 on this project -- and took 1.3-3.2s a call, past
  `get_next_requirement`'s deadline, so every checkout was told the graph was
  rebuilding while the projector sat idle.

  Asserted on rows fetched, never on duration: the same read over a checkout
  with 300 more file rows must fetch about the same number of rows. The old
  read fetched each new file row twice. The checkout's harness reports its
  overlay for each scan, as a live one does. A read after the copy's files move
  digests them once to see the report still answers for them
  (`CopyOverlay.verdicts_at/1`); the reads after it do not.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures
  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Files.File
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{CopyOverlay, IncrementalGraph, Preloader, RequirementGraph}
  alias CodeMySpec.Requirements.StoryExecution
  alias Ecto.Adapters.SQL.Sandbox

  @added_files 300

  setup do
    :ok = Sandbox.checkout(Repo)
    scope = full_scope_fixture()
    story_fixture(scope, %{ready_for_dev: true})
    {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id, [scope.active_working_copy_id])
    %{scope: scope}
  end

  test "a read over 300 more file rows fetches about the same rows", %{scope: scope} do
    report(scope)
    _first = StoryExecution.read(scope, :coding)
    before = rows_fetched(fn -> StoryExecution.read(scope, :coding) end)

    add_files(scope, @added_files)
    report(scope)
    _first = StoryExecution.read(scope, :coding)
    later = rows_fetched(fn -> StoryExecution.read(scope, :coding) end)

    assert later - before < div(@added_files, 10),
           "a discovery read fetched #{later} rows after #{@added_files} file rows were " <>
             "added, against #{before} before: it is loading the checkout's files, which " <>
             "only a compute needs"
  end

  test "the read context serves exactly what the full preload serves", %{scope: scope} do
    add_files(scope, 5)
    {:ok, full} = Preloader.load(scope)
    read = RequirementGraph.read_context(scope)

    {full_nodes, full_edges} = RequirementGraph.served_graph(scope, full)
    {nodes, edges} = RequirementGraph.served_graph(scope, read)

    assert full_nodes != [], "the fixture projected no rows, so this compares nothing"
    assert Enum.sort(nodes) == Enum.sort(full_nodes)
    assert Enum.sort(edges) == Enum.sort(full_edges)
  end

  # The overlay the copy's harness sends for its scan of these files.
  defp report(scope) do
    files =
      Repo.all(
        from(f in File,
          where: f.working_copy_id == ^scope.active_working_copy_id,
          select: map(f, [:path, :role, :valid, :validation_errors, :size, :fingerprint])
        )
      )

    {read_model, _payload} = CopyOverlay.served_read_model(scope)

    {:ok, _} =
      CopyOverlay.report(scope, %{
        "read_model" => read_model.fingerprint,
        "files" => CopyOverlay.files_digest(files),
        "verdicts" => CopyOverlay.verdicts(files, read_model)
      })
  end

  defp add_files(scope, count) do
    now = NaiveDateTime.utc_now()

    rows =
      for n <- 1..count do
        %{
          path: "lib/padding/file_#{n}.ex",
          role: :implementation,
          project_id: scope.active_project_id,
          working_copy_id: scope.active_working_copy_id,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(File, rows)
  end

  # Rows the database returned to this process; the projector's own drains run
  # in its process and are not the read's cost.
  defp rows_fetched(fun) do
    handler = "discovery-rows-#{inspect(make_ref())}"
    counter = :counters.new(1, [:atomics])
    owner = self()

    :telemetry.attach(
      handler,
      [:code_my_spec, :repo, :query],
      fn _event, _measurements, meta, _config ->
        count_rows(self() == owner, meta, counter)
      end,
      nil
    )

    fun.()
    :telemetry.detach(handler)
    :counters.get(counter, 1)
  end

  defp count_rows(true, %{result: {:ok, %{num_rows: rows}}}, counter) when is_integer(rows),
    do: :counters.add(counter, 1, rows)

  defp count_rows(_mine?, _meta, _counter), do: :ok
end
