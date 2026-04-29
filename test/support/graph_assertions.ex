defmodule CodeMySpecSpex.GraphAssertions do
  @moduledoc """
  Surface-layer helpers for asserting on the requirements graph view.

  The graph LiveView (`/projects/:name/requirements/graph`) renders
  the projected graph as JSON inside a `data-graph` attribute on the
  `#sigma-graph` element. This module pulls that JSON back out so
  specs can assert on graph structure (nodes, edges, satisfaction)
  without hard-coding sigma-specific markup or reaching into the
  Requirements context directly.

  All functions take the rendered HTML string and return either
  parsed graph data or pass/fail assertions. No DB reads, no context
  calls — strictly surface observation.
  """

  @doc """
  Pull the graph data out of the rendered LiveView HTML.

  Returns `%{"nodes" => [...], "edges" => [...]}` on success,
  raises with a descriptive message if the attribute is missing or
  unparseable.
  """
  @spec extract_graph!(String.t()) :: %{String.t() => list()}
  def extract_graph!(html) when is_binary(html) do
    case Regex.run(~r/data-graph="([^"]+)"/, html) do
      [_, encoded] ->
        encoded
        |> html_unescape()
        |> Jason.decode!()

      nil ->
        raise "data-graph attribute not found in rendered HTML — graph view may not have rendered"
    end
  end

  @doc """
  Find a node by its (entity_type, entity_id, name) tuple. Returns
  the node map or `nil`.

  Node keys in the projected graph use the form
  `"<type>_<id>_<name>"` — see `GraphProjector.key_to_string/1`.
  """
  @spec find_node(map(), String.t(), term(), String.t()) :: map() | nil
  def find_node(graph, entity_type, entity_id, name) do
    expected_key = node_key(entity_type, entity_id, name)
    Enum.find(graph["nodes"], fn n -> n["key"] == expected_key end)
  end

  @doc """
  Returns the list of edges originating from `from_key`.
  """
  @spec edges_from(map(), String.t()) :: [map()]
  def edges_from(graph, from_key) do
    Enum.filter(graph["edges"], fn e -> e["source"] == from_key end)
  end

  @doc """
  Returns the list of edges pointing at `to_key`.
  """
  @spec edges_to(map(), String.t()) :: [map()]
  def edges_to(graph, to_key) do
    Enum.filter(graph["edges"], fn e -> e["target"] == to_key end)
  end

  @doc """
  True iff an edge exists from `from_key` to `to_key`.
  """
  @spec edge?(map(), String.t(), String.t()) :: boolean()
  def edge?(graph, from_key, to_key) do
    Enum.any?(graph["edges"], fn e ->
      e["source"] == from_key and e["target"] == to_key
    end)
  end

  @doc """
  Build a node key the way `GraphProjector.key_to_string/1` does.
  """
  @spec node_key(String.t(), term(), String.t()) :: String.t()
  def node_key(entity_type, entity_id, name) do
    "#{entity_type}_#{sanitize_id(entity_id)}_#{name}"
  end

  defp sanitize_id(id) when is_integer(id), do: "#{id}"
  defp sanitize_id(id) when is_binary(id), do: String.replace(id, "-", "")

  defp html_unescape(s) do
    s
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end
end
