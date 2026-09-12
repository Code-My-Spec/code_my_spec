defmodule CodeMySpec.McpServers.MainAgent.AnswersMapper do
  @moduledoc """
  Past decisions, written out so they can be used.

  Each result carries the question, what the user decided, and the id — all
  three are needed to act on it: `answer_question` wants the id, the agent wants
  the decision, and the main agent needs the question's own words to judge
  whether it is the same question or merely a similar one.
  """

  alias Anubis.Server.Response
  alias CodeMySpec.Utils.MapAccess

  @spec results([map()]) :: Response.t()
  def results([]) do
    Response.tool()
    |> Response.text("""
    The user has answered nothing matching that.

    Nothing to carry forward, so this one is either answerable from the
    project's records or theirs to decide.
    """)
  end

  def results(found) do
    Response.tool()
    |> Response.text("""
    #{length(found)} decision(s) the user has already made:

    #{Enum.map_join(found, "\n\n", &entry/1)}

    Use one with `answer_question`: basis `precedent`, `precedent_id` the id
    above. It is checked — a similar question is not the same question.
    """)
  end

  @spec error(term()) :: Response.t()
  def error(reason) do
    Response.tool() |> Response.error("Could not search: #{inspect(reason)}")
  end

  defp entry(request) do
    """
      id: #{request.id}
      asked: #{Enum.map_join(request.questions, "; ", &MapAccess.get(&1, :question))}
      decided: #{decided(request.answers)}\
    """
  end

  defp decided(answers) when map_size(answers) == 0, do: "(nothing recorded)"

  defp decided(answers) do
    Enum.map_join(answers, "; ", fn {question, answer} -> "#{question} → #{said(answer)}" end)
  end

  defp said(answer) when is_list(answer), do: Enum.join(answer, ", ")
  defp said(answer), do: to_string(answer)
end
