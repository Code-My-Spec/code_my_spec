defmodule CodeMySpec.ProjectSync.StatusWriter do
  @moduledoc """
  Writes markdown status files to .code_my_spec/status/ as flat root-level files.

  Every component gets a single file at the root of .code_my_spec/status/ with dots
  separating module parts in the filename:

      .code_my_spec/status/
        metric_flow.md                  # root summary: lists all contexts
        metric_flow.accounts.md         # Accounts context + all descendants inline
        metric_flow.integrations.md     # Integrations + providers inline
        metric_flow_web.md              # root summary for web
        metric_flow_web.auth.md         # Auth context + descendants

  Bounded contexts are the unit of work, so each context file gives an agent
  the complete picture — which children need specs, tests, or implementation —
  in a single read.
  """

  require Logger

  alias CodeMySpec.Components.Registry
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Stories.Story

  @status_dir CodeMySpec.Paths.status_dir()

  @doc """
  Writes status files for components only (backward-compatible).

  Delegates to `write_status_files/4` with empty stories and nil project.
  """
  @spec write_status_files([map()], Environment.t()) :: [String.t()]
  def write_status_files(root_components, env) do
    write_status_files(root_components, [], nil, env)
  end

  @doc """
  Writes status files for components, stories, and the project.

  Expects root components with child_components populated recursively
  (as returned by HierarchicalTree.build).

  Root components get a summary file listing their child contexts.
  Each child context gets its own file with all descendants inline.
  Stories and project get their own status files.

  Returns list of written file paths (relative to environment cwd).
  """
  @spec write_status_files([map()], [Story.t()], Project.t() | nil, Environment.t()) :: [
          String.t()
        ]
  def write_status_files([], [], nil, _env), do: []
  def write_status_files([], [], _project, _env), do: []

  def write_status_files(root_components, stories, project, %Environment{} = env) do
    component_files = write_component_status_files(root_components, env)
    story_files = write_stories_status(stories, env)
    project_files = write_project_status(project, env)

    component_files ++ story_files ++ project_files
  end

  defp write_component_status_files([], _env), do: []

  defp write_component_status_files(root_components, env) do
    Enum.flat_map(root_components, fn root ->
      children = root.child_components || []
      contexts = group_into_contexts(root, children)

      root_path = component_path(root)
      root_content = render_root_summary(root, contexts)
      write_file(env, root_path, root_content)

      context_files =
        contexts
        |> Enum.sort_by(& &1.name)
        |> Enum.map(fn context ->
          context_path = component_path(context)
          descendants = collect_descendants(context)
          context_content = render_context(context, descendants)
          write_file(env, context_path, context_content)
          context_path
        end)

      [root_path | context_files]
    end)
  end

  defp collect_descendants(component) do
    children = component.child_components || []

    Enum.flat_map(children, fn child ->
      [child | collect_descendants(child)]
    end)
    |> Enum.sort_by(& &1.name)
  end

  # Groups flat children into context-level groupings.
  #
  # When children sit more than one module segment below their root
  # (e.g. MyAppWeb.AiLive.Chat under MyAppWeb), they are grouped under
  # a virtual intermediate context node (MyAppWeb.AiLive).
  # Direct children (one segment below root) remain as-is.
  defp group_into_contexts(root, children) do
    root_prefix = root.module_name <> "."

    groups =
      Enum.group_by(children, fn child ->
        relative = String.replace_prefix(child.module_name, root_prefix, "")

        case String.split(relative, ".") do
          [_single] -> :direct
          [context_name | _rest] -> context_name
        end
      end)

    direct = Map.get(groups, :direct, [])

    virtual_contexts =
      groups
      |> Map.delete(:direct)
      |> Enum.map(fn {context_name, members} ->
        type = "live_context"

        %{
          module_name: root_prefix <> context_name,
          name: context_name,
          type: type,
          child_components: Enum.sort_by(members, & &1.name),
          requirements: default_requirements_for_type(type)
        }
      end)

    Enum.sort_by(direct ++ virtual_contexts, & &1.name)
  end

  defp default_requirements_for_type(type) do
    type
    |> Registry.get_requirements_for_type()
    |> Enum.map(fn req_def ->
      %{name: req_def.name, description: req_def.description, satisfied: false}
    end)
  end

  @doc """
  Returns `{satisfied_count, total_count}` for a context and all its descendants.

  Collects all requirements from the context itself plus every descendant component.
  A context is considered complete when all requirements are satisfied AND total > 0.
  """
  @spec context_completion(map()) :: {non_neg_integer(), non_neg_integer()}
  def context_completion(context) do
    all_components = [context | collect_descendants(context)]

    all_requirements =
      Enum.flat_map(all_components, fn comp ->
        comp.requirements || []
      end)

    total = length(all_requirements)
    satisfied = Enum.count(all_requirements, & &1.satisfied)
    {satisfied, total}
  end

  # Hierarchical path under .code_my_spec/status/.
  # MetricFlow → .code_my_spec/status/metric_flow.md
  # MetricFlow.Accounts → .code_my_spec/status/metric_flow/accounts.md
  def component_path(component) do
    parts =
      component.module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    {dir_parts, [filename]} = Enum.split(parts, -1)

    Path.join([@status_dir | dir_parts] ++ ["#{filename}.md"])
  end

  defp write_file(env, path, content) do
    case Environments.write_file(env, path, content) do
      :ok -> :ok
      {:error, reason} -> Logger.error("[StatusWriter] FAILED #{path}: #{inspect(reason)}")
    end
  end

  # --- Project & Stories status files ---

  defp write_project_status(nil, _env), do: []

  defp write_project_status(%Project{} = project, env) do
    path = Path.join(@status_dir, "project.md")
    content = render_project_status(project)
    write_file(env, path, content)
    [path]
  end

  defp write_stories_status([], _env), do: []

  defp write_stories_status(stories, env) do
    path = Path.join(@status_dir, "stories.md")
    content = render_stories_index(stories)
    write_file(env, path, content)
    [path]
  end

  # --- Rendering ---

  defp render_root_summary(root, children) do
    type_label = root.type || "module"
    lines = ["# #{root.module_name} (#{type_label})\n"]

    # Component requirements
    lines = lines ++ render_requirements(root)

    # Contexts section
    lines =
      if children != [] do
        context_list =
          children
          |> Enum.sort_by(& &1.name)
          |> Enum.map(&render_context_line/1)

        lines ++ ["\n## Contexts\n"] ++ context_list ++ [""]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp render_context_line(child) do
    path = component_path(child)
    {satisfied, total} = context_completion(child)
    checkbox = if satisfied == total and total > 0, do: "[x]", else: "[ ]"
    "- #{checkbox} [#{child.module_name}](#{path}) (#{satisfied}/#{total})"
  end

  defp render_context(context, descendants) do
    lines = ["# #{context.module_name}\n"]
    lines = lines ++ render_component_section(context)

    lines =
      Enum.reduce(descendants, lines, fn child, acc ->
        acc ++ render_component_section(child)
      end)

    Enum.join(lines, "\n")
  end

  defp render_component_section(component) do
    header = "\n## #{component.module_name} (#{component.type || "module"})\n"
    [header | render_requirements(component)] ++ [""]
  end

  defp render_requirements(component) do
    requirements = component.requirements || []

    if requirements == [] do
      ["_No requirements defined_\n"]
    else
      Enum.map(requirements, &render_requirement/1)
    end
  end

  defp render_requirement(req) do
    checkbox = if req.satisfied, do: "[x]", else: "[ ]"
    "- #{checkbox} #{req.name} - #{req.description}"
  end

  # --- Project status rendering ---

  defp render_project_status(%Project{} = project) do
    requirements = project.requirements || []
    lines = ["# #{project.name} — Project Status\n"]

    lines =
      if requirements != [] do
        req_lines = Enum.map(requirements, &render_requirement/1)
        lines ++ ["\n## Project Requirements\n"] ++ req_lines ++ [""]
      else
        lines ++ ["_No project requirements defined_\n"]
      end

    Enum.join(lines, "\n")
  end

  # --- Stories index rendering ---

  defp render_stories_index(stories) do
    {complete, total} = stories_completion(stories)
    lines = ["# Stories\n"]
    lines = lines ++ ["\n## Summary\n", "#{complete}/#{total} stories complete (all requirements satisfied)\n"]

    story_sections =
      stories
      |> Enum.sort_by(fn s -> s.priority || 999 end)
      |> Enum.flat_map(&render_story/1)

    lines = lines ++ ["\n## Stories\n"] ++ story_sections

    Enum.join(lines, "\n")
  end

  # --- Single story rendering (for stories index) ---

  defp render_story(story) do
    requirements = story.requirements || []
    status = story.status || :in_progress
    priority = story.priority

    component_label =
      case story do
        %{component: %{module_name: name}} when is_binary(name) -> name
        _ -> nil
      end

    meta_parts = ["Status: #{status}"]
    meta_parts = if priority, do: meta_parts ++ ["Priority: #{priority}"], else: meta_parts
    meta_parts = meta_parts ++ ["Component: #{component_label || "—"}"]

    lines = [
      "\n### ##{story.id} — #{story.title}\n",
      Enum.join(meta_parts, " | ") <> "\n"
    ]

    if requirements != [] do
      req_lines = Enum.map(requirements, &render_requirement/1)
      lines ++ req_lines ++ [""]
    else
      lines ++ ["_No requirements defined_\n"]
    end
  end

  # --- Story completion helpers ---

  @doc """
  Returns true if all requirements on the story are satisfied (and there is at least one).
  """
  @spec story_complete?(Story.t()) :: boolean()
  def story_complete?(story) do
    requirements = story.requirements || []
    requirements != [] and Enum.all?(requirements, & &1.satisfied)
  end

  @doc """
  Returns `{complete_count, total_count}` across a list of stories.
  """
  @spec stories_completion([Story.t()]) :: {non_neg_integer(), non_neg_integer()}
  def stories_completion(stories) do
    total = length(stories)
    complete = Enum.count(stories, &story_complete?/1)
    {complete, total}
  end
end
