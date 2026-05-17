defmodule CodeMySpec.McpServers.Stories.Tools.CreateStory do
  @moduledoc """
  Creates a user story with title and description.

  Acceptance criteria are NOT created here — they emerge from Three
  Amigos as rule-bearing scenarios, never invented up-front. Run
  `start_three_amigos_session` after creating the story.

  Example:
    title: "User Login"
    description: "As a user, I want to log in so I can access my account"
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :title, :string, required: true, doc: "Story title (e.g., 'User Login Feature')"

    field :description, :string,
      required: true,
      doc:
        "User story in 'As a [role], I want [goal] so that [value]' format. " <>
          "The role MUST be a real human (user, admin, manager) - never a system, API, or service. " <>
          "Focus on business value, not technical implementation."

    field :priority, :integer,
      doc: "Priority order (1 = highest). Lower numbers are higher priority."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, story} <- Stories.create_story(scope, params) do
      {:reply, StoriesMapper.story_response(story), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
