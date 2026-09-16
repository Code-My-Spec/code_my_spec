defmodule CodeMySpec.McpServers.Requirements.Tools.ListRequirements do
  @moduledoc """
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

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Requirements

  schema do
    field :status, :string,
      doc:
        "Filter by satisfaction status — `satisfied` or `unsatisfied`. Default: no filter (returns both)."

    field :entity_type, :string,
      doc: "Filter to one entity type — `project`, `story`, or `component`."

    field :entity_id, :string,
      doc:
        "Filter to one entity by id (a story id or a component id, as printed elsewhere — " <>
          "accepts either a number or a string). Combine with `entity_type` to disambiguate " <>
          "when ids collide across types. Previously accepted and silently ignored (`69b418e0`); " <>
          "now actually narrows the result."

    field :requirement_name, :string,
      doc:
        "Exact match on the requirement name (e.g., `tests_passing`, `test_file`, `spec_valid`)."

    field :module_filter, :string,
      doc:
        "Substring match on the component module name (e.g., `Users.` to scope into a namespace)."

    field :summary, :boolean,
      doc:
        "Return aggregate counts by requirement name instead of per-entity rows. Default: `false` (per-entity view, matches the historical tool shape). Pass `true` for a friction breakdown that won't blow the token budget on big projects."

    field :limit, :integer,
      doc:
        "Cap number of per-entity rows when `summary` is false. Default: 100. Bounds the response so a 500-component project doesn't return 180k+ chars."

    field :diagnostic, :boolean,
      doc:
        "When `summary: true`, break out counts into `locally failing` vs `blocked by prereqs` (clamped). Useful for triage — distinguishes real friction from cascade effects. Default: false."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        # The read model, not a recompute. `project_graph/1` recomputes every
        # node and edge on every call — 4.4s on a 3200-component project — and
        # this tool is agent-facing, so it paid that per invocation to produce a
        # graph the projection already holds. `cached_all/1` recomputes on a
        # fingerprint miss, so it is never stale.
        {nodes, _computed_at} = Requirements.cached_all(scope)

        opts = parse_opts(params)
        filtered = apply_filters(nodes, opts)

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

        {:reply, response, frame}

      {:error, reason} ->
        {:reply, RequirementsMapper.error(reason), frame}
    end
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

  # Compared as strings on both sides: a story's entity_id is an integer and a
  # component's is a UUID string, and a caller may pass either shape (`69b418e0`
  # reproduced with both `965` and `"965"` to rule out a type-coercion cause).
  defp filter_by_entity_id(nodes, nil), do: nodes

  defp filter_by_entity_id(nodes, id) do
    id = to_string(id)
    Enum.filter(nodes, &(to_string(&1.entity_id) == id))
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
