defmodule CodeMySpec.Questions.QuestionsRepository do
  @moduledoc """
  Ecto queries for Three Amigos questions (red cards). All queries
  scoped to the active account/project.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Questions.Question
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type attrs :: map()

  @spec create_question(Scope.t(), integer() | String.t(), attrs()) ::
          {:ok, Question.t()}
          | {:error,
             :missing_active_scope
             | :story_not_found
             | :cross_account
             | Ecto.Changeset.t()}
  def create_question(
        %Scope{active_account_id: account_id, active_project_id: project_id},
        story_id,
        attrs
      )
      when not is_nil(account_id) and not is_nil(project_id) do
    story_id = coerce_story_id(story_id)

    with {:story, %Story{} = story} <- {:story, Repo.get(Story, story_id)},
         {:account, %Story{account_id: ^account_id, project_id: ^project_id}} <-
           {:account, story} do
      attrs =
        attrs
        |> normalize()
        |> Map.put(:account_id, account_id)
        |> Map.put(:project_id, project_id)
        |> Map.put(:story_id, story.id)

      %Question{}
      |> Question.changeset(attrs)
      |> Repo.insert()
    else
      {:story, nil} -> {:error, :story_not_found}
      {:account, %Story{}} -> {:error, :cross_account}
    end
  end

  def create_question(%Scope{}, _story_id, _attrs), do: {:error, :missing_active_scope}

  @spec list_questions_for_story(Scope.t(), integer() | String.t()) :: [Question.t()]
  def list_questions_for_story(%Scope{active_account_id: account_id}, story_id)
      when not is_nil(account_id) do
    story_id = coerce_story_id(story_id)

    Question
    |> where([q], q.account_id == ^account_id and q.story_id == ^story_id)
    |> order_by([q], asc: q.inserted_at, asc: q.id)
    |> Repo.all()
  end

  def list_questions_for_story(%Scope{}, _story_id), do: []

  @spec get_question(Scope.t(), Ecto.UUID.t()) :: Question.t() | nil
  def get_question(%Scope{active_account_id: account_id}, id) when not is_nil(account_id) do
    Question
    |> where([q], q.account_id == ^account_id and q.id == ^id)
    |> Repo.one()
  end

  def get_question(%Scope{}, _id), do: nil

  @spec update_question(Scope.t(), Question.t(), attrs()) ::
          {:ok, Question.t()} | {:error, :missing_active_account | :cross_account | Ecto.Changeset.t()}
  def update_question(%Scope{active_account_id: account_id}, %Question{} = question, attrs)
      when not is_nil(account_id) do
    if question.account_id == account_id do
      question
      |> Question.changeset(Map.delete(normalize(attrs), :account_id))
      |> Repo.update()
    else
      {:error, :cross_account}
    end
  end

  def update_question(%Scope{}, _question, _attrs), do: {:error, :missing_active_account}

  @spec delete_question(Scope.t(), Question.t()) ::
          {:ok, Question.t()} | {:error, :missing_active_account | :cross_account}
  def delete_question(%Scope{active_account_id: account_id}, %Question{} = question)
      when not is_nil(account_id) do
    if question.account_id == account_id do
      Repo.delete(question)
    else
      {:error, :cross_account}
    end
  end

  def delete_question(%Scope{}, _question), do: {:error, :missing_active_account}

  defp coerce_story_id(id) when is_integer(id), do: id
  defp coerce_story_id(id) when is_binary(id), do: String.to_integer(id)

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError -> attrs
  end
end
