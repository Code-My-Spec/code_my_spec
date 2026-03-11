defmodule CodeMySpec.McpServers.Stories.Tools.CreateStory do
  @moduledoc """
  Creates a user story with title, description, and acceptance criteria.

  Example:
    title: "User Login"
    description: "As a user, I want to log in so I can access my account"
    acceptance_criteria: ["User can enter email and password", "Invalid credentials show error"]
  """

  use Hermes.Server.Component, type: :tool

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

    field :acceptance_criteria, {:list, :string},
      required: true,
      doc: "List of acceptance criteria strings"

    field :priority, :integer,
      doc: "Priority order (1 = highest). Lower numbers are higher priority."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         story_params <- transform_params(params),
         {:ok, story} <- Stories.create_story(scope, story_params) do
      {:reply, StoriesMapper.story_response(story), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end

  # Transform acceptance_criteria strings to criteria nested params
  defp transform_params(params) do
    criteria =
      params
      |> Map.get(:acceptance_criteria, [])
      |> Enum.map(fn description -> %{description: description} end)

    params
    |> Map.delete(:acceptance_criteria)
    |> Map.put(:criteria, criteria)
  end
end
