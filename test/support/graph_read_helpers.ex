defmodule CodeMySpecSpex.GraphReadHelpers do
  @moduledoc """
  Reading the cached requirement graph the way a client does.

  `GET /api/projects/:project_name/requirements/graph` answers the **cached**
  graph with the diagnostics needed to tell whether it moved: `computed_at`,
  the watcher's state, and the nodes. The markdown `/requirements` endpoint
  cannot be used for this — it calls `compute_all/1` and so recomputes on every
  request by construction, which makes every cache question unanswerable.

  Every criterion on stories 1062 and 1063 observes the graph this way, so it
  lives here rather than being copied into each of them.

  ## Warming

  A cold cache computes, stores, and answers `computed_at: nil` while doing it.
  Measuring from that first read compares "no cached graph yet" against "a
  cached graph", which is a difference none of these criteria are about — so
  `warm_graph/1` reads once and discards, and the reading that matters comes
  after it.
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

  @doc "Put a graph in the cache, so the next read measures a cached answer."
  def warm_graph(context) do
    _cold = read_graph(context)
    context
  end

  @doc """
  Read after a change, skipping the miss the change caused.

  `computed_at: nil` means "this read computed the answer", not "there is no
  answer" — a cache miss computes, stores, and reports nil while doing it. So
  any read taken immediately after an invalidating write measures the miss
  rather than the result, and comparing it to anything is comparing against
  nil.

  Use this whenever the question is about the state the change left behind
  rather than about the change landing. Three specs tripped on this before it
  was named.
  """
  def read_settled_graph(context) do
    _miss = read_graph(context)
    read_graph(context)
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
