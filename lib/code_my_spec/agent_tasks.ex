defmodule CodeMySpec.AgentTasks do
  @moduledoc """
  Shared helpers for agent task modules.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AcceptanceCriteria,
      CodeMySpec.Analysis,
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
      CodeMySpec.Paths,
      CodeMySpec.Problems,
      CodeMySpec.ProjectSync,
      CodeMySpec.Projects,
      CodeMySpec.PublicUrl,
      CodeMySpec.Qa,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Resources,
      CodeMySpec.Rules,
      CodeMySpec.Sessions,
      CodeMySpec.Stories,
      CodeMySpec.Users,
      CodeMySpec.Utils
    ],
    exports: :all

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
