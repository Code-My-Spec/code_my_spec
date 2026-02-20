defmodule CodeMySpec.ProjectSync.StatusWriter do
  @moduledoc """
  Writes markdown status files to docs/status/ as flat root-level files.

  Every component gets a single file at the root of docs/status/ with dots
  separating module parts in the filename:

      docs/status/
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

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  @status_dir "docs/status"

  @doc """
  Writes status files for a hierarchical tree of components.

  Expects root components with child_components populated recursively
  (as returned by HierarchicalTree.build).

  Root components get a summary file listing their child contexts.
  Each child context gets its own file with all descendants inline.
  All files are written flat in docs/status/.

  Returns list of written file paths (relative to environment cwd).
  """
  @spec write_status_files([map()], Environment.t()) :: [String.t()]
  def write_status_files([], _env), do: []

  def write_status_files(root_components, %Environment{} = env) do
    written_files =
      Enum.flat_map(root_components, fn root ->
        children = root.child_components || []

        root_path = component_path(root)
        root_content = render_root_summary(root, children)
        write_file(env, root_path, root_content)

        context_files =
          children
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

    written_files
  end

  defp collect_descendants(component) do
    children = component.child_components || []

    Enum.flat_map(children, fn child ->
      [child | collect_descendants(child)]
    end)
    |> Enum.sort_by(& &1.name)
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

  # Hierarchical path under docs/status/.
  # MetricFlow → docs/status/metric_flow.md
  # MetricFlow.Accounts → docs/status/metric_flow/accounts.md
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

  # --- Rendering ---

  defp render_root_summary(root, children) do
    type_label = root.type || "module"
    lines = ["# #{root.module_name} (#{type_label})\n"]

    lines = lines ++ render_requirements(root)

    if children != [] do
      context_list =
        children
        |> Enum.sort_by(& &1.name)
        |> Enum.map(&render_context_line/1)

      lines = lines ++ ["\n## Contexts\n"] ++ context_list ++ [""]
      Enum.join(lines, "\n")
    else
      Enum.join(lines, "\n")
    end
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
end
