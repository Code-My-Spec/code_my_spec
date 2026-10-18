defmodule CodeMySpec.Stories.Tools.CreateStory do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories

  @impl true
  def name, do: "create_story"

  @impl true
  def description do
    """
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
  end

  @impl true
  def params do
    %{
      priority:
        {:meta, :integer,
         [description: "Priority order (1 = highest). Lower numbers are higher priority."]},
      description:
        {:meta, :string,
         [description: "Legacy alias for `story`. Prefer `story`; the two are kept in sync."]},
      title:
        {:required, {:meta, :string, [description: "Story title (e.g., 'User Login Feature')"]}},
      story:
        {:meta, :string,
         [
           description:
             "User story in 'As a [role], I want [goal] so that [value]' format. The role MUST be a real human (user, admin, manager) - never a system, API, or service. Keep it to the sentence — mechanism, dependencies and caveats belong in `notes`. Either `story` or `description` must be given; they are kept in sync."
         ]},
      notes:
        {:meta, :string,
         [
           description:
             "Working notes for the agent — mechanism, dependencies, caveats (optional)"
         ]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, story} <- Stories.create_story(scope, params) do
      StoriesMapper.story_response(story)
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        StoriesMapper.validation_error(changeset)

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end
end
