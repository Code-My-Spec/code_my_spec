defmodule CodeMySpecWeb.QuestionsJSON do
  alias CodeMySpec.Questions.Question

  def index(%{questions: questions}) do
    %{data: Enum.map(questions, &data/1)}
  end

  def show(%{question: question}) do
    %{data: data(question)}
  end

  defp data(%Question{} = question) do
    %{
      id: question.id,
      account_id: question.account_id,
      project_id: question.project_id,
      story_id: question.story_id,
      text: question.text,
      status: question.status,
      inserted_at: question.inserted_at,
      updated_at: question.updated_at
    }
  end
end
