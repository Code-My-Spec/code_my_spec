defmodule CodeMySpec.Issues.Projector do
  @moduledoc false

  alias CodeMySpec.Environments
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Paths

  @doc "Projects a single issue to the appropriate filesystem location."
  @spec project_issue(Environments.Environment.t(), Issue.t()) :: :ok
  def project_issue(env, %Issue{status: :dismissed}), do: remove_projection(env, %Issue{})
  def project_issue(env, %Issue{} = issue) do
    remove_projection(env, issue)
    dir = dir_for_status(issue.status)
    filename = build_filename(issue)
    path = Path.join(dir, filename)
    content = build_content(issue)
    Environments.ensure_dir(env, dir)
    Environments.write_file(env, path, content)
    :ok
  end

  @doc "Re-projects all active issues. Clears and rebuilds."
  @spec project_all(Environments.Environment.t(), [Issue.t()]) :: :ok
  def project_all(env, issues) do
    clear_directories(env)

    issues
    |> Enum.reject(&(&1.status == :dismissed))
    |> Enum.each(&project_issue(env, &1))

    :ok
  end

  @doc "Removes any projected file for an issue from all directories."
  @spec remove_projection(Environments.Environment.t(), Issue.t()) :: :ok
  def remove_projection(env, %Issue{} = issue) do
    filename = build_filename(issue)

    for dir <- [Paths.issues_incoming_dir(), Paths.issues_accepted_dir()] do
      Environments.delete_file(env, Path.join(dir, filename))
    end

    :ok
  end

  @doc "Generates the projection filename for an issue."
  @spec build_filename(Issue.t()) :: String.t()
  def build_filename(%Issue{} = issue) do
    slug = slugify(issue.title)
    prefix = if issue.story_id, do: "qa-#{issue.story_id}", else: "braindump"
    "#{prefix}-#{slug}.md"
  end

  @doc "Builds the markdown content for a projected issue file."
  @spec build_content(Issue.t()) :: String.t()
  def build_content(%Issue{} = issue) do
    source = build_source(issue)
    resolution = build_resolution(issue)

    """
    # #{issue.title}

    ## Status

    #{issue.status}

    ## Severity

    #{issue.severity}

    ## Scope

    #{issue.scope || "app"}

    ## Description

    #{issue.description}

    ## Source

    #{source}
    #{resolution}\
    """
  end

  # Private

  defp dir_for_status(:incoming), do: Paths.issues_incoming_dir()
  defp dir_for_status(:accepted), do: Paths.issues_accepted_dir()
  defp dir_for_status(:resolved), do: Paths.issues_accepted_dir()

  defp build_source(%Issue{story_id: nil}), do: "Braindump import"
  defp build_source(%Issue{story_id: story_id, source_path: path}) when is_binary(path) do
    "QA Story #{story_id} — `#{path}`"
  end
  defp build_source(%Issue{story_id: story_id}) do
    "QA Story #{story_id}"
  end

  defp build_resolution(%Issue{status: :resolved, resolution: resolution}) when is_binary(resolution) do
    """

    ## Resolution

    #{resolution}
    """
  end
  defp build_resolution(_issue), do: ""

  defp slugify(nil), do: "untitled"
  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim_leading("_")
    |> String.trim_trailing("_")
    |> String.slice(0..40)
  end

  defp clear_directories(env) do
    for dir <- [Paths.issues_incoming_dir(), Paths.issues_accepted_dir()] do
      case Environments.glob(env, Path.join(dir, "*.md")) do
        files when is_list(files) ->
          Enum.each(files, &Environments.delete_file(env, &1))
        _ -> :ok
      end
    end

    Environments.ensure_dir(env, Paths.issues_incoming_dir())
    Environments.ensure_dir(env, Paths.issues_accepted_dir())
  end
end
