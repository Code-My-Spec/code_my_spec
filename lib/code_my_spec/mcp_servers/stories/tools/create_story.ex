defmodule CodeMySpec.McpServers.Stories.Tools.CreateStory do
  @moduledoc """
  Creates a user story.

  The story sentence and the agent's working notes are separate fields:
  `story` holds "As a [role], I want [goal] so that [value]" and nothing
  else; `notes` is where mechanism, dependencies and caveats go.

  New stories are **not ready for development** — they produce no
  requirements until released. Use `update_story` with
  `ready_for_dev: true`, or release a whole epic at once.

  Acceptance criteria are NOT created here — they emerge from Three
  Amigos as rule-bearing scenarios, never invented up-front. Run
  `start_three_amigos_session` after creating the story.

  Example:
    title: "User Login"
    story: "As a user, I want to log in so I can access my account"
    notes: "Blocked on the identity provider migration"
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :title, :string, required: true, doc: "Story title (e.g., 'User Login Feature')"

    field :story, :string,
      doc:
        "User story in 'As a [role], I want [goal] so that [value]' format. " <>
          "The role MUST be a real human (user, admin, manager) - never a system, API, or service. " <>
          "Keep it to the sentence — mechanism, dependencies and caveats belong in `notes`. " <>
          "Either `story` or `description` must be given; they are kept in sync."

    field :notes, :string,
      doc: "Working notes for the agent — mechanism, dependencies, caveats (optional)"

    field :description, :string,
      doc: "Legacy alias for `story`. Prefer `story`; the two are kept in sync."

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
