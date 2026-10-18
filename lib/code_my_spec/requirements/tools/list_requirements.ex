defmodule CodeMySpec.Requirements.Tools.ListRequirements do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories

  alias CodeMySpec.Requirements.Tools.Responses, as: RequirementsMapper
  alias CodeMySpec.Requirements

  @impl true
  def name, do: "list_requirements"

  @impl true
  def description do
    """
    List project requirements with their satisfaction status — filterable.

    **The default is every requirement, satisfied and not, one row each, capped at
    100** — `status` unset, `summary: false`, `limit: 100`. Those defaults are
    deliberate and `parse_opts/1` says why: the tool predates its filters and
    existing callers ask it for the full picture.

    **For "where is the friction", ask for it:**

        summary: true, status: "unsatisfied"

    Both parts matter. `summary: true` alone counts *all* requirements, which on
    this project reads `implementation_file: 900` — a number that looks like a
    catastrophic regression and is in fact 900 satisfied requirements. An agent
    who takes it as friction goes hunting a break that does not exist; this
    paragraph exists because that happened, off a moduledoc that claimed the
    unfiltered default was a summary of unsatisfied requirements. It is neither.
    With both set the same project reads 55.

    The size warning is still real and is the reason `summary` exists: with a 500+
    component project the raw per-entity dump runs 180k+ characters and can exceed
    tool-response token limits. `limit` bounds it; the summary avoids it.

    This is a read-only discovery tool — use it to understand the full picture
    of what needs doing before picking a requirement to work on.
    """
  end

  @impl true
  def params do
    %{
      status:
        {:meta, :string,
         [
           description:
             "Filter by satisfaction status — `satisfied` or `unsatisfied`. Default: no filter (returns both)."
         ]},
      limit:
        {:meta, :integer,
         [
           description:
             "Cap number of per-entity rows when `summary` is false. Default: 100. Bounds the response so a 500-component project doesn't return 180k+ chars."
         ]},
      diagnostic:
        {:meta, :boolean,
         [
           description:
             "When `summary: true`, break out counts into `locally failing` vs `blocked by prereqs` (clamped). Useful for triage — distinguishes real friction from cascade effects. Default: false."
         ]},
      story_number:
        {:meta, :integer,
         [
           description:
             "A story's number — the same as entity_type `story` with entity_id set to it"
         ]},
      summary:
        {:meta, :boolean,
         [
           description:
             "Return aggregate counts by requirement name instead of per-entity rows. Default: `false` (per-entity view, matches the historical tool shape). Pass `true` for a friction breakdown that won't blow the token budget on big projects."
         ]},
      entity_id:
        {:meta, :string,
         [
           description:
             "Filter to one entity: a story's number or a component's id, as printed elsewhere. Combine with `entity_type` to disambiguate."
         ]},
      requirement_name:
        {:meta, :string,
         [
           description:
             "Exact match on the requirement name (e.g., `bdd_specs_exist`, `ready_for_qa`, `implementation_file`)."
         ]},
      entity_type:
        {:meta, :string,
         [description: "Filter to one entity type — `project`, `story`, or `component`."]},
      module_filter:
        {:meta, :string,
         [
           description:
             "Substring match on the component module name (e.g., `Users.` to scope into a namespace)."
         ]}
    }
  end

  @impl true
  def call(params, context) do
    case filtered_nodes(params, context) do
      {:ok, filtered, opts} ->
        response =
          if opts.summary do
            RequirementsMapper.requirements_summary_response(filtered, opts)
          else
            limited = Enum.take(filtered, opts.limit)

            RequirementsMapper.list_requirements_response(limited,
              total: length(filtered),
              opts: opts
            )
          end

        response

      {:error, reason} ->
        RequirementsMapper.error(reason)
    end
  end

  @impl true
  def script_result(params, context) do
    case filtered_nodes(params, context) do
      {:ok, filtered, %{summary: true}} ->
        {:ok, filtered |> summary_groups() |> Enum.map(&summary_row/1)}

      {:ok, filtered, opts} ->
        {:ok, filtered |> Enum.take(opts.limit) |> Enum.map(&row/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The read model, not a recompute. `project_graph/1` recomputes every node
  # and edge on every call — 4.4s on a 3200-component project — and this tool
  # is agent-facing, so it paid that per invocation to produce a graph the
  # projection already holds. `cached_all/1` recomputes on a fingerprint miss,
  # so it is never stale.
  #
  # Lifted out of `execute/2` so the script path runs the same query rather
  # than a second copy of it.
  defp filtered_nodes(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context) do
      opts = parse_opts(params)
      {nodes, _computed_at} = Requirements.cached_all(at_story_copy(scope, opts))

      {:ok, apply_filters(CodeMySpec.Requirements.Directives.number_nodes(scope, nodes), opts),
       opts}
    end
  end

  # Read where the queried story is assigned, not where the caller is. A
  # story's requirements are computed at its own copy, so a caller filtering
  # by one story must not read it through its own, possibly different,
  # active copy's graph -- the same gap `ShowStoryRequirements.at_story_copy/2`
  # was fixed for (d4d04dd04); this tool was its unfixed sibling (f66cc07a).
  # `StoryRefs.normalize_args/2` already collapses a caller's `story_number`
  # into `entity_type: "story"` + `entity_id` before this ever runs, so that
  # pair is the one signal to gate on.
  defp at_story_copy(scope, %{entity_type: "story", entity_id: id}) when not is_nil(id) do
    case Stories.fetch_story_by_number(scope, id) do
      {:ok, %{working_copy_id: copy_id}} when is_binary(copy_id) ->
        %{scope | active_working_copy_id: copy_id}

      _ ->
        scope
    end
  end

  defp at_story_copy(scope, _opts), do: scope

  defp summary_groups(nodes), do: Enum.group_by(nodes, & &1.name)

  defp summary_row({name, group}) do
    %{
      "name" => name,
      "count" => length(group),
      "locally_failing" => Enum.count(group, &(not &1.satisfied))
    }
  end

  # String keys and plain values: these cross into a Lua VM, where an atom
  # key and a struct are not things that exist.
  defp row(node) do
    %{
      "name" => node.name,
      "entity_type" => node.entity_type,
      "entity_id" => to_string(CodeMySpec.Requirements.Directives.entity_ref(node)),
      "entity_name" => node.entity_name,
      "satisfied" => node.satisfied,
      "description" => node.description
    }
  end

  defp parse_opts(params) do
    # Defaults match the tool's historical shape so existing callers
    # (spex tests, agents asking "what's the full picture") don't get
    # surprised: status=all, summary=false (per-entity view), limit=100.
    # The previous tool ignored params entirely; the new filters are
    # strictly opt-in.
    status = get_param(params, :status)
    entity_type = get_param(params, :entity_type)
    entity_id = get_param(params, :entity_id)
    requirement_name = get_param(params, :requirement_name)
    module_filter = get_param(params, :module_filter)
    limit = get_param(params, :limit) || 100
    summary = get_param(params, :summary) == true
    diagnostic = get_param(params, :diagnostic) == true

    %{
      status: status,
      entity_type: entity_type,
      entity_id: entity_id,
      requirement_name: requirement_name,
      module_filter: module_filter,
      summary: summary,
      limit: limit,
      diagnostic: diagnostic
    }
  end

  defp apply_filters(nodes, opts) do
    nodes
    |> filter_by_status(opts.status)
    |> filter_by_entity_type(opts.entity_type)
    |> filter_by_entity_id(opts.entity_id)
    |> filter_by_requirement_name(opts.requirement_name)
    |> filter_by_module(opts.module_filter)
  end

  defp filter_by_status(nodes, "satisfied"), do: Enum.filter(nodes, & &1.satisfied)
  defp filter_by_status(nodes, "unsatisfied"), do: Enum.reject(nodes, & &1.satisfied)
  defp filter_by_status(nodes, _), do: nodes

  defp filter_by_entity_type(nodes, nil), do: nodes

  defp filter_by_entity_type(nodes, type) when is_binary(type),
    do: Enum.filter(nodes, &(&1.entity_type == type))

  # Compared as strings: a story is named by its number, a component by its
  # uuid, and a caller may pass either as a string or a number (`69b418e0`).
  defp filter_by_entity_id(nodes, nil), do: nodes

  defp filter_by_entity_id(nodes, ref) do
    ref = to_string(ref)
    Enum.filter(nodes, &(to_string(CodeMySpec.Requirements.Directives.entity_ref(&1)) == ref))
  end

  defp filter_by_requirement_name(nodes, nil), do: nodes

  defp filter_by_requirement_name(nodes, name) when is_binary(name),
    do: Enum.filter(nodes, &(&1.name == name))

  defp filter_by_module(nodes, nil), do: nodes

  defp filter_by_module(nodes, substr) when is_binary(substr) do
    Enum.filter(nodes, fn node ->
      is_binary(node.entity_name) and String.contains?(node.entity_name, substr)
    end)
  end

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
