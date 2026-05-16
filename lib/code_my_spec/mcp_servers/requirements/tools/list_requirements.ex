defmodule CodeMySpec.McpServers.Requirements.Tools.ListRequirements do
  @moduledoc """
  List project requirements with their satisfaction status — filterable.

  The unfiltered default is **summary mode**: aggregate counts of unsatisfied
  requirements grouped by requirement name. With a 500+ component project the
  raw per-entity dump can run 180k+ characters and exceed tool-response token
  limits; the summary tells you where the friction lives in one line, then
  you drill in with the filter params.

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
        %{nodes: nodes} = Requirements.project_graph(scope)

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
    requirement_name = get_param(params, :requirement_name)
    module_filter = get_param(params, :module_filter)
    limit = get_param(params, :limit) || 100
    summary = get_param(params, :summary) == true
    diagnostic = get_param(params, :diagnostic) == true

    %{
      status: status,
      entity_type: entity_type,
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
    |> filter_by_requirement_name(opts.requirement_name)
    |> filter_by_module(opts.module_filter)
  end

  defp filter_by_status(nodes, "satisfied"), do: Enum.filter(nodes, & &1.satisfied)
  defp filter_by_status(nodes, "unsatisfied"), do: Enum.reject(nodes, & &1.satisfied)
  defp filter_by_status(nodes, _), do: nodes

  defp filter_by_entity_type(nodes, nil), do: nodes

  defp filter_by_entity_type(nodes, type) when is_binary(type),
    do: Enum.filter(nodes, &(&1.entity_type == type))

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
