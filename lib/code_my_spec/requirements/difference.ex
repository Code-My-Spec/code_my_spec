defmodule CodeMySpec.Requirements.Difference do
  @moduledoc """
  Says what differs between the projection and the payload, in words.

  This exists because the comparison it replaces reported a disagreement as
  `nodes 13 vs 13, edges 12 vs 12` — two identical numbers and the word
  "differs". The check was `{^nodes, ^edges}`, exact structural equality, so it
  fired on a field or an ordering while the message could only talk about
  counts. A warning nobody can act on is worse than no warning: it trains the
  reader to skip the line, and this line is the gate for retiring the payload.

  So: order is not a difference, `nil` and its stored default are not a
  difference, and anything that *is* one gets named — which side has it, which
  requirement, which field.
  """

  alias CodeMySpec.Requirements.{Requirement, Topology}

  @sample 3

  @doc """
  Describe how the projection and the payload disagree, or `:none`.

  `:none` covers the two non-differences. **Ordering**: rows come back by id,
  the computed graph in computation order, and a list comparison calls that a
  mismatch on every read. **The stored default**: the write turns nil details
  into `%{}`, so a round trip returns "nothing" spelled the other way.

  Only `satisfied` and `details` are compared. Everything else on a node —
  description, execution type, subagent role — rehydrates from the definition
  registry rather than from the row, so the two sides cannot disagree about it
  without the registry disagreeing with itself.

  Neither is a defect, and reporting them as one buries the defects that matter.
  """
  @spec describe([Requirement.t()], [term()], [Requirement.t()], [term()]) :: String.t() | :none
  def describe(read_nodes, read_edges, nodes, edges) do
    [
      compare("node", read_nodes, nodes, &node_key/1, &node_fields/1),
      compare("edge", read_edges, edges, & &1, fn _ -> %{} end)
    ]
    |> Enum.reject(&(&1 == :none))
    |> case do
      [] -> :none
      parts -> Enum.join(parts, "; ") <> " — serving the projection"
    end
  end

  defp compare(label, read, computed, key_fun, fields_fun) do
    read_by_key = Map.new(read, &{key_fun.(&1), &1})
    computed_by_key = Map.new(computed, &{key_fun.(&1), &1})

    only_read = Map.keys(read_by_key) -- Map.keys(computed_by_key)
    only_computed = Map.keys(computed_by_key) -- Map.keys(read_by_key)
    shared = Map.keys(read_by_key) -- only_read

    field_diffs = field_differences(shared, read_by_key, computed_by_key, fields_fun)

    case {only_read, only_computed, field_diffs} do
      {[], [], []} -> :none
      _ -> phrase(label, only_read, only_computed, field_diffs)
    end
  end

  defp field_differences(shared, read_by_key, computed_by_key, fields_fun) do
    Enum.flat_map(shared, fn key ->
      read_fields = fields_fun.(Map.fetch!(read_by_key, key))
      computed_fields = fields_fun.(Map.fetch!(computed_by_key, key))

      case changed_fields(read_fields, computed_fields) do
        [] -> []
        changed -> [{key, changed}]
      end
    end)
  end

  # Enum rather than a comprehension, because `computed_value = Map.get(...)` as
  # a comprehension clause is a *filter*: the assignment evaluates to the value,
  # and a falsy one drops the entry. `satisfied: false` is exactly that — the
  # verdict most worth reporting was the one silently skipped.
  defp changed_fields(read_fields, computed_fields) do
    Enum.flat_map(read_fields, fn {field, read_value} ->
      computed_value = Map.get(computed_fields, field)

      if equivalent?(read_value, computed_value),
        do: [],
        else: [{field, read_value, computed_value}]
    end)
  end

  # The write defaults nil details to `%{}`, so the two spell "nothing"
  # differently and mean the same thing. Nothing else is forgiven: `false`
  # against `true` is the verdict changing, and `nil` against `false` is a
  # requirement that was never computed.
  defp equivalent?(read, computed), do: empty_as_nothing(read) == empty_as_nothing(computed)

  defp empty_as_nothing(nil), do: :nothing
  defp empty_as_nothing(map) when map_size(map) == 0, do: :nothing
  defp empty_as_nothing(other), do: other

  defp phrase(label, only_read, only_computed, field_diffs) do
    [
      side("only in the projection", label, only_read),
      side("only in the payload", label, only_computed),
      fields_phrase(label, field_diffs)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp side(_where, _label, []), do: nil

  defp side(where, label, keys) do
    "#{length(keys)} #{label}#{plural(keys)} #{where} (#{sample(keys)})"
  end

  defp fields_phrase(_label, []), do: nil

  defp fields_phrase(label, diffs) do
    detail =
      diffs
      |> Enum.take(@sample)
      |> Enum.map_join(", ", fn {key, changed} ->
        fields =
          Enum.map_join(changed, " and ", fn {f, r, c} -> "#{f} #{inspect(r)}≠#{inspect(c)}" end)

        "#{describe_key(key)}: #{fields}"
      end)

    "#{length(diffs)} #{label}#{plural(diffs)} disagree on a field (#{detail})"
  end

  defp sample(keys) do
    shown = keys |> Enum.take(@sample) |> Enum.map_join(", ", &describe_key/1)
    if length(keys) > @sample, do: shown <> ", …", else: shown
  end

  defp describe_key({entity_type, entity_id, name}), do: "#{name} on #{entity_type} #{entity_id}"
  defp describe_key(%{from: from, to: to}), do: "#{describe_key(from)} → #{describe_key(to)}"
  defp describe_key(other), do: inspect(other)

  defp plural([_one]), do: ""
  defp plural(_many), do: "s"

  defp node_key(node), do: Topology.node_key(node)

  # `satisfied` is the field that matters — it is the verdict an agent acts on,
  # and the whole reason to compare the two at all. `details` rides along
  # because it is what a reader is shown when a requirement is unmet.
  defp node_fields(node), do: %{satisfied: node.satisfied, details: node.details}
end
