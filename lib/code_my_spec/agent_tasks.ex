defmodule CodeMySpec.AgentTasks do
  @moduledoc """
  Shared helpers for agent task modules.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.PromotionQueue,
      CodeMySpec.Agents.Agent,
      CodeMySpec.Stories,
      CodeMySpec.TaskOwner,
      CodeMySpec.Architecture,
      CodeMySpec.Auth,
      CodeMySpec.BddSpecs,
      CodeMySpec.Components,
      CodeMySpec.Configurations,
      CodeMySpec.Deploys,
      CodeMySpec.Documents,
      CodeMySpec.Environments,
      CodeMySpec.Files,
      CodeMySpec.Issues,
      CodeMySpec.LocalScope,
      CodeMySpec.Paths,
      CodeMySpec.Problems,
      CodeMySpec.Projects,
      CodeMySpec.Promotion,
      CodeMySpec.PublicUrl,
      CodeMySpec.Qa,
      CodeMySpec.Questions,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Resources,
      CodeMySpec.Rules,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  @doc """
  Resolve the environment for the selected working copy, or the active local project.

  A selected copy is authoritative: if it is invalid or unavailable, this
  returns nil rather than falling back to the project's local environment.
  """
  def environment(%{active_working_copy_id: id} = scope) when not is_nil(id),
    do: CodeMySpec.WorkingCopies.environment(scope)

  def environment(scope), do: CodeMySpec.LocalScope.environment(scope.active_project)

  @doc """
  Validate an explicitly requested artifact without adding it to the work graph.

  The test authoring command still checks its output, reading the checkout's
  file projection directly.
  """
  def artifact_feedback(scope, component, role) do
    key = %{test: :test_file}[role]
    path = Map.fetch!(CodeMySpec.Utils.component_files(component, scope.active_project), key)

    case CodeMySpec.Files.get_by_path(scope, path) do
      nil -> "#{role} file missing: #{path}"
      %{valid: false} -> "#{role} file invalid: #{path}"
      %{valid: nil} when role != :test -> "#{role} file has not been validated: #{path}"
      _ -> nil
    end
  end

  @doc """
  Renders a task module's `{:error, reason}` for a human or an agent to read.

  Task modules return `{:error, {tag, message}}` where the message explains
  what to do about it — `get_story_component/2` in `WriteBddSpecs`, for
  instance, names the two tools that resolve an unlinked story. `inspect/1` on
  that tuple buries the message in escaped quotes on one line, and callers that
  render only the tag drop it entirely. Issue 3b943635 is exactly that: the
  agent saw `Error generating prompt: :component_not_linked` and had to guess
  the remedy that the tuple was already carrying.

  So every surface that renders a task error goes through here.

  ## Examples

      iex> CodeMySpec.AgentTasks.format_error({:component_not_linked, "Link it."})
      "component_not_linked\\n\\nLink it."

      iex> CodeMySpec.AgentTasks.format_error(:timeout)
      ":timeout"
  """
  @spec format_error(term()) :: String.t()
  def format_error({tag, message}) when is_atom(tag) and is_binary(message) do
    "#{tag}\n\n#{message}"
  end

  def format_error(reason), do: inspect(reason)
end
