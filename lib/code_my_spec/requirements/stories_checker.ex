defmodule CodeMySpec.Requirements.StoriesChecker do
  @moduledoc """
  Delegate checker for the `stories_exist` requirement on `project_graph`.

  Confirms the active project has at least one user story. Acceptance
  criteria are not required at this stage — they're produced later by
  the Three Amigos pass on each story.

  Returns `{boolean(), map()}` per the checker contract.
  """

  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @doc """
  The verdict, from a fact the caller already has.

  `exist?/2` asks the database. `Requirements.Handlers` has already read this
  project's stories into a profile, and a rollup that queries for itself on
  every drain is the thing profiles exist to replace.
  """
  @spec verdict(boolean()) :: {boolean(), map()}
  def verdict(true), do: {true, %{}}

  def verdict(false),
    do:
      {false,
       %{
         reason:
           "No stories exist for this project. Start a story interview to create the first one."
       }}

  @spec exist?(Scope.t(), term()) :: {boolean(), map()}
  def exist?(%Scope{active_project_id: project_id} = scope, _entity)
      when not is_nil(project_id) do
    if Stories.project_has_stories?(scope) do
      {true, %{}}
    else
      {false,
       %{
         reason:
           "No stories exist for this project. Start a story interview to create the first one."
       }}
    end
  end

  def exist?(%Scope{}, _entity) do
    {false, %{reason: "No active project in scope — cannot check stories."}}
  end
end
