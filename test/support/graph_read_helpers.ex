defmodule CodeMySpecSpex.GraphReadHelpers do
  @moduledoc """
  Reading the cached requirement graph the way a client does.

  `GET /api/projects/:project_name/requirements/graph` answers the **cached**
  graph: the nodes with their verdicts, plus the watcher's state. The markdown
  `/requirements` endpoint cannot be used for this — it calls `compute_all/1`
  and so recomputes on every request by construction, which makes every cache
  question unanswerable.

  Every criterion on stories 1062 and 1063 observes the graph this way, so it
  lives here rather than being copied into each of them.

  ## Assert an effect, not `computed_at`

  These criteria used to read `computed_at` and assert it had moved. That was
  never a sound claim, for two reasons that only became visible once reads
  stopped recomputing:

    * It says a *pass ran*, not that the write was applied. A pass that read
      the change and did nothing with it moves `computed_at` exactly as far as
      one that applied it.
    * `checked_at` is a `:naive_datetime` — second resolution. A write and the
      recompute that answers it land in the same second constantly, so the
      timestamps come back equal whether or not anything happened. Measured on
      criterion 3343: `before: "2026-09-13T19:29:24", after: "2026-09-13T19:29:24"`
      on a pass that did run.

  So a criterion names the requirement the write bears on and asserts its
  verdict — `satisfaction_of/2` and `requirement/2` below. Filing an issue is
  claimed by `issues_triaged` going unsatisfied, not by a clock moving.

  ## Nothing computes unless something announces

  Reads serve rows. `GraphWatcher` is the only thing that writes them, driven
  by writers publishing through `Requirements.GraphInputs`. `setup_active_project`
  starts a watcher for the project, so a graph exists to read; a write that
  announces nothing leaves it exactly as it was, which is the condition these
  criteria exist to catch.
  """

  alias Phoenix.ConnTest

  @doc "Read the cached graph for the project in this context."
  def read_graph(context), do: dispatch(context, "")

  @doc """
  Read the cached graph as one working copy sees it.

  A requirement graph is a statement about a checkout. Without one the
  preloader reads every checkout's files together, warning that a file present
  in one and absent in another reads as present — so any question about a
  particular copy has to name it.
  """
  def read_graph(context, working_copy_id),
    do: dispatch(context, "?working_copy=#{working_copy_id}")

  @doc """
  Put a graph in the cache, so the next read measures a cached answer.

  Kept because a criterion reads better saying it out loud, and because the
  first read of a vantage no pass has computed is the one that gets that
  vantage into `Projection.vantages/1`.
  """
  def warm_graph(context) do
    _cold = read_graph(context)
    context
  end

  @doc """
  Read after a change, skipping the miss the change caused.

  This dates from when a read recomputed: `computed_at: nil` meant "this read
  computed the answer" rather than "there is no answer", so a read taken
  straight after an invalidating write measured the miss instead of the result.

  Reads no longer compute, so the second read is no longer covering for
  anything — but it is still the honest shape for a caller that wants the
  settled state, and the first read is what registers a new vantage.
  """
  def read_settled_graph(context) do
    _first = read_graph(context)
    read_graph(context)
  end

  @doc """
  One requirement out of a graph read, by name, or `nil`.

  `nil` is a real answer and a common one: a requirement exists only while its
  entity does, so a story that has not been released produces no nodes at all.
  """
  def requirement(graph, name) do
    Enum.find(graph["nodes"] || [], &(&1["name"] == name))
  end

  @doc """
  One requirement belonging to a named entity — the per-entity questions.

  `entity_id` is compared as a string, because the API answers JSON and a story
  id arrives as a number on one side and a string on the other.
  """
  def requirement(graph, name, entity_type, entity_id) do
    Enum.find(graph["nodes"] || [], fn node ->
      node["name"] == name and
        node["entity_type"] == to_string(entity_type) and
        to_string(node["entity_id"]) == to_string(entity_id)
    end)
  end

  @doc """
  Whether a named requirement is satisfied: `true`, `false`, or `nil` when
  there is no such node.

  Three values on purpose. "Absent" and "unsatisfied" are different findings —
  absent usually means the entity is gone or was never released, and collapsing
  it into `false` turns a missing graph into a passing assertion.
  """
  def satisfaction_of(graph, name) do
    case requirement(graph, name) do
      nil -> nil
      node -> node["satisfied"]
    end
  end

  def satisfaction_of(graph, name, entity_type, entity_id) do
    case requirement(graph, name, entity_type, entity_id) do
      nil -> nil
      node -> node["satisfied"]
    end
  end

  @doc """
  One requirement on a named entity — `requirement_on(graph, "spec_file", "MyApp.Accounts")`.

  The precise form, and the one most of these criteria want. A name alone is
  ambiguous wherever a requirement is stamped per entity: `ProjectBuilder.new/2`
  writes `lib/my_app.ex`, so the root context already satisfies
  `implementation_file` before the scenario does anything, and a criterion
  asking "is any implementation_file satisfied" reads `true` from the fixture
  rather than from the change it made.
  """
  def requirement_on(graph, name, entity_name) do
    Enum.find(graph["nodes"] || [], fn node ->
      node["name"] == name and node["entity_name"] == entity_name
    end)
  end

  @doc "Whether a named requirement on a named entity is satisfied — `true`, `false`, or `nil` if absent."
  def satisfaction_on(graph, name, entity_name) do
    case requirement_on(graph, name, entity_name) do
      nil -> nil
      node -> node["satisfied"]
    end
  end

  @doc """
  Why a requirement is still open, in the checker's own words.

  Some inputs cannot move a verdict on their own and still plainly move the
  graph: adding the last scenario to a rule takes `three_amigos_complete` from
  "Rule X has no scenarios" to "ready to seal but has not been sealed", and
  both of those are `false`. The reason is the effect there, and asserting the
  verdict would call a working writer broken.
  """
  def reason_for(graph, name, entity_type, entity_id) do
    case requirement(graph, name, entity_type, entity_id) do
      nil -> nil
      node -> (node["details"] || %{})["reason"] || (node["details"] || %{})["status"]
    end
  end

  @doc """
  Whether *any* node by this name is satisfied.

  The right grain when a name is stamped per entity and the criterion is about
  one of them appearing. A context carries a `spec_file` for itself and one per
  child, so `satisfaction_of/2` picks whichever `Enum.find/2` reaches first and
  a criterion written on it asserts nothing in particular — it read `false` off
  an unsatisfied child while the spec that had just been written was sitting
  satisfied two nodes along.
  """
  def any_satisfied?(graph, name) do
    Enum.any?(graph["nodes"] || [], &(&1["name"] == name and &1["satisfied"] == true))
  end

  @doc "Every node by this name, with its entity and verdict — for describing a failure."
  def all_named(graph, name) do
    Enum.filter(graph["nodes"] || [], &(&1["name"] == name))
  end

  @doc """
  When the watcher last completed a pass, to microsecond precision.

  The one observable for a criterion whose subject is *that a pass happened*
  rather than what it changed — a redundant event, by construction, changes no
  verdict and no `checked_at`. `DateTime.utc_now/0` carries microseconds where
  `checked_at` is a second-resolution `:naive_datetime`, so this discriminates
  where the node timestamps cannot.

  Reach for it only when there is genuinely nothing in the graph to claim.
  Everywhere else the verdict is the better assertion: a pass that ran and
  applied nothing advances this exactly as far as one that worked.
  """
  def last_recompute(graph), do: (graph["watcher"] || %{})["last_recompute"]

  @doc "Every requirement name in a graph read, sorted — for describing a failure."
  def requirement_names(graph) do
    (graph["nodes"] || []) |> Enum.map(& &1["name"]) |> Enum.sort() |> Enum.uniq()
  end

  defp dispatch(context, query) do
    ConnTest.build_conn()
    |> ConnTest.dispatch(
      CodeMySpecLocalWeb.Endpoint,
      :get,
      "/api/projects/#{context.project.name}/requirements/graph" <> query
    )
    |> ConnTest.json_response(200)
  end
end
