defmodule CodeMySpec.Issues.Tools.AcceptIssue do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Tools.Responses, as: IssuesMapper
  alias CodeMySpec.Stories.StoryRefs

  @impl true
  def name, do: "accept_issue"

  @impl true
  def description do
    """
    Accepts an incoming issue for triage.

    Transitions the issue from incoming → accepted.
    """
  end

  @impl true
  def params do
    %{
      category:
        {:meta, :string,
         [
           description:
             "Disposition category: 'bug' (default) or 'requirements_change' (requires story_number)"
         ]},
      story_number:
        {:meta, :integer, [description: "Optional number of the story to link this issue to"]},
      issue_id: {:required, {:meta, :string, [description: "Issue ID to accept"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, story_id} <- StoryRefs.story_id(scope, params[:story_number]),
         opts =
           []
           |> maybe_put(:story_id, story_id)
           |> maybe_put(:category, parse_category(params[:category])),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         {:ok, updated} <- Issues.accept_issue(scope, issue, opts) do
      IssuesMapper.issue_updated_response(updated, "accepted")
    else
      nil -> IssuesMapper.not_found_error()
      {:error, %Ecto.Changeset{} = cs} -> IssuesMapper.validation_error(cs)
      {:error, reason} -> IssuesMapper.error(reason)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_category(nil), do: nil
  defp parse_category("bug"), do: :bug
  defp parse_category("requirements_change"), do: :requirements_change
  defp parse_category(other) when is_atom(other), do: other
  defp parse_category(_), do: nil
end
