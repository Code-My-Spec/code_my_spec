defmodule CodeMySpec.Requirements.Freshness do
  @moduledoc """
  What one entity's requirements were computed from, as a fingerprint.

  Every node carries its entity's fingerprint as `inputs_fingerprint`, so a
  reader can tell whether a row is current. `topology/2` fingerprints the shape
  the edges were drawn from, which gates edge redraws.

  In: every row a checker for that entity reads, keyed `{id, updated_at}`. Out:
  anything no checker reads. Files are keyed by content hash; a QA attempt or a
  git state by its id or revision.

  See knowledge/requirements_graph/checkers, "Fingerprints".
  """

  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.RequirementDefinitionData

  @doc """
  One story's inputs, as a fingerprint.

  Never `nil`: a story with no files and no rules has the fingerprint of having
  none; `nil` would read as "unknown".
  """
  @spec story(Preloader.context(), map()) :: String.t()
  def story(ctx, story) do
    hash([
      {:story, story.id, row_key(story), story.ready_for_dev, story.working_copy_id,
       story.component_id},
      {:files, file_keys(Map.get(ctx.files_by_story, story.id, []))},
      {:rules, row_keys(Map.get(ctx.rules_by_story, story.id, []))},
      {:criteria, row_keys(Map.get(ctx.criteria_by_story, story.id, []))},
      {:questions, row_keys(Map.get(ctx.questions_by_story, story.id, []))},
      {:personas, row_keys(Map.get(ctx.personas_by_story, story.id, []))},
      {:qa, attempt_key(Map.get(ctx.qa_latest_by_story, story.id))},
      {:deploy, deploy_key(Map.get(ctx.uat_deploy_by_story, story.id))},
      # The setup steps `deploy` names while it waits; setup completing has to
      # move the story, or the node stays unoffered after the work is possible.
      {:setup_missing, Map.get(ctx, :setup_missing)},
      {:running_copy, Map.get(ctx, :delegated_inputs, %{}) |> Map.get("working_copies")},
      # Triage and each inherited issue submission are scoped to this story.
      {:issues, Map.get(ctx, :issues_by_story, %{}) |> Map.get(story.id, [])},
      config_part(ctx)
    ])
  end

  @doc """
  One component's inputs, as a fingerprint.

  Children are included by id, not by their own fingerprint: a context's
  requirements depend on which children it has, not on their specs.

  Analyzer runs and problems are not inputs: no component requirement reads
  them.
  """
  @spec component(Preloader.context(), map()) :: String.t()
  def component(ctx, component) do
    hash([
      {:component, component.id, row_key(component), component.type, component.module_name},
      {:files, file_keys(Map.get(ctx.files_by_component, component.id, []))},
      {:children, ids(Map.get(ctx.children_by_parent, component.id, []))},
      config_part(ctx)
    ])
  end

  @doc """
  Stamp the configuration onto a context, so every fingerprint taken from it
  covers the definitions the configuration leaves standing.

  Config decides which requirement definitions exist (`devops: :off` removes
  `devops_setup`; the specs/reviews/tests switches remove artifact types), and
  is no input to a story or component, so it is stamped here once per pass and
  every entity's fingerprint moves when a switch moves. `reduce_to/2` keeps the
  stamp, so a partial pass hashes what a whole one would.
  """
  @spec with_config(Preloader.context(), map()) :: Preloader.context()
  def with_config(ctx, config), do: Map.put(ctx, :config_shape, hash(config_shape(config)))

  # `nil` when nobody stamped it.
  defp config_part(ctx), do: {:config, Map.get(ctx, :config_shape)}

  @doc """
  The shape the graph's edges describe, as a fingerprint.

  An edge comes from the template (by `component.type`, filtered by config and
  the definition set), the component tree (`parent_component_id`), cross-context
  `dependencies`, story attachment (`story.component_id`), and which discovered
  components have files on this checkout. Nothing else: validity, QA results
  and deploys move nodes, never edges.

  This gates edges only; verdicts are moved by marks. `IncrementalGraph` redraws
  a vantage's edges when this moves and reuses an edge plan while it holds.
  See knowledge/requirements_graph/checkers, "Fingerprints".
  """
  @spec topology(Preloader.context(), map()) :: String.t()
  def topology(ctx, config) do
    ctx |> topology_parts(config) |> Enum.sort() |> hash()
  end

  @doc """
  Each shared input's stamps, digested separately, so a recompute can name
  which one moved.

  `delegated_inputs` are project-wide, so one moving changes every fingerprint
  that hashes them; the per-table digests say which table it was.
  """
  @spec delegated_parts(Preloader.context()) :: %{String.t() => String.t()}
  def delegated_parts(ctx) do
    ctx
    |> Map.get(:delegated_inputs, %{})
    |> Map.new(fn {table, stamps} -> {table, hash(stamps)} end)
  end

  @doc """
  The topology's inputs, hashed separately, so a reader can say which moved.

  `topology/2` is these parts, sorted, and nothing else.
  """
  @spec topology_parts(Preloader.context(), map()) :: %{atom() => String.t()}
  def topology_parts(ctx, config) do
    components =
      ctx.components
      |> Enum.map(
        &{&1.id, &1.type, &1.parent_component_id, dependency_ids(&1), Map.get(&1, :provenance)}
      )
      |> Enum.sort()

    stories = ctx.stories |> Enum.map(&{&1.id, &1.component_id}) |> Enum.sort()

    %{
      components: hash(components),
      discovered_files: hash(discovered_files(ctx)),
      stories: hash(stories),
      story_issues:
        hash(
          Enum.map(
            Map.get(ctx, :story_issues, []),
            &{&1.id, &1.story_id, &1.status, &1.severity, &1.assigned_working_copy_id}
          )
          |> Enum.sort()
        ),
      config: hash(config_shape(config)),
      definitions: hash(definition_shape(ctx))
    }
  end

  defp discovered_files(ctx) do
    present =
      Map.get_lazy(ctx, :file_component_ids, fn ->
        ctx
        |> Map.get(:files_by_component, %{})
        |> Enum.reject(fn {_id, files} -> files == [] end)
        |> MapSet.new(fn {id, _files} -> id end)
      end)

    ctx.components
    |> Enum.filter(&(Map.get(&1, :provenance) == :discovered and MapSet.member?(present, &1.id)))
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  # The definition set itself (names and prerequisites only), so a release that
  # moves a prerequisite moves the edges. Sorted at both levels so list order
  # cannot flap it; belongs in `topology_parts/2` only.
  # See knowledge/requirements_graph/checkers, "Fingerprints".
  defp definition_shape(ctx) do
    types = ctx.components |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort()

    graphs =
      [
        RequirementDefinitionData.story_graph(),
        RequirementDefinitionData.story_issue_graph(),
        RequirementDefinitionData.project_graph()
      ] ++
        Enum.map(types, &RequirementDefinitionData.graph_for_type/1)

    graphs
    |> Enum.map(fn graph -> Enum.map(graph, &{&1.id, &1.name, &1.prerequisites}) end)
    |> Enum.sort()
  end

  # An unloaded association is not an empty one: `[]` would hash two shapes
  # alike, so it is named and always looks changed.
  defp dependency_ids(component) do
    case component.dependencies do
      deps when is_list(deps) -> deps |> Enum.map(& &1.id) |> Enum.sort()
      _ -> :not_loaded
    end
  end

  # Only the keys the definition filters read (the struct carries timestamps),
  # and the devops level, not the column: a legacy nil and :off are one shape.
  defp config_shape(config),
    do: [
      devops: ProjectConfiguration.devops_level(config),
      fix_issues_min_severity: Map.get(config, :fix_issues_min_severity)
    ]

  @doc """
  The project's own inputs, as a fingerprint.

  Deliberately coarse: project requirements read counts rather than contents,
  so this hashes story and component ids, project files and the delegated
  inputs.
  """
  @spec project(Preloader.context()) :: String.t()
  def project(ctx) do
    hash([
      {:stories, ids(ctx.stories)},
      {:components, ids(ctx.components)},
      {:files, file_keys(Map.get(ctx, :files_by_project, []))},
      {:delegated, Map.get(ctx, :delegated_inputs, %{})}
    ])
  end

  # A file's identity for this purpose is its path, its content hash and
  # whether it parsed — the three things a `file_exists` or `file_valid` check
  # reads. Sorted, because the order a query returned them in is not a change.
  defp file_keys(files) do
    files
    |> Enum.map(&{&1.path, Map.get(&1, :fingerprint), Map.get(&1, :valid)})
    |> Enum.sort()
  end

  defp ids(rows), do: rows |> Enum.map(& &1.id) |> Enum.sort()

  # `{id, updated_at}`, not named fields: these rows are edited in place and
  # checkers read their contents. See knowledge/requirements_graph/checkers,
  # "Fingerprints".
  defp row_keys(rows), do: rows |> Enum.map(&row_key/1) |> Enum.sort()

  # The same key for one row, including the entity's own.
  defp row_key(row), do: {row.id, Map.get(row, :updated_at)}

  # An attempt is immutable once inserted, so its id identifies it; its
  # invalidations are what make a pass stop counting.
  defp attempt_key(nil), do: nil

  defp attempt_key(attempt) do
    {attempt.id, attempt.status, length(Map.get(attempt, :invalidations, []) || [])}
  end

  defp deploy_key(nil), do: nil
  defp deploy_key(deploy), do: {deploy.id, Map.get(deploy, :status)}

  defp hash(terms) do
    terms
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end
end
