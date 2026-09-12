defmodule CodeMySpec.McpServers.MainAgent.MainAgentMapper do
  @moduledoc """
  How the main agent's view is written out for it to read.

  ## Two sections, and neither one is a heading

  Criterion 3264 turns on this. An escalated question is still open and still
  listed — it has not been handled and it has not gone away — but it is not
  work the main agent can do anything about, and a list that mixes the two
  makes the main agent answer its own escalations or learn to skim them.

  So a question appears under the holder it actually has, and a section with
  nothing in it is not printed. That is not formatting: "needs your attention"
  standing over an empty list is the same false statement as an escalated
  question sitting under it.
  """

  alias Anubis.Server.Response
  alias CodeMySpec.MainAgent.OpenQuestion

  @doc "Everything waiting, grouped by who is holding it."
  @spec listing([OpenQuestion.t()]) :: Response.t()
  def listing([]) do
    Response.tool()
    |> Response.text("""
    Nothing is waiting on you.

    Every agent on this project is either working or finished — none of them is
    blocked on an answer.
    """)
  end

  def listing(questions) do
    {mine, theirs} = Enum.split_with(questions, &(&1.holder == "main_agent"))

    Response.tool()
    |> Response.text(Enum.join(sections(mine, theirs), "\n"))
  end

  @doc "What one escalation looks like once it has gone up."
  @spec escalated(OpenQuestion.t()) :: Response.t()
  def escalated(%OpenQuestion{} = question) do
    Response.tool()
    |> Response.text("""
    Sent to the user: #{question.escalation_reason}

    #{render(question)}
    They have it now. It stays open and stays in your listing — you do not need
    to do anything else with it, and the agent that asked has been told where it
    went.
    """)
  end

  @doc "Why a question could not be escalated, in terms that say what to do."
  @spec error(term()) :: Response.t()
  def error(:not_found) do
    Response.tool()
    |> Response.error("""
    No open question on this project has that id.

    Either it has already been answered, or it belongs to another project's \
    agents — you can only act on your own. Call `list_open_questions` for what \
    is actually waiting.\
    """)
  end

  def error(:needs_a_reason) do
    Response.tool()
    |> Response.error("""
    An escalation needs a reason.

    The user gets the question and your account of why it reached them. Without \
    it they have to work out for themselves why they are being asked, which is \
    the work you were escalating in order to save them.\
    """)
  end

  def error(reason) do
    Response.tool() |> Response.error("Could not escalate: #{inspect(reason)}")
  end

  defp sections(mine, theirs) do
    Enum.reject(
      [
        section("Needs your attention", mine),
        section("Waiting on the user", theirs)
      ],
      &is_nil/1
    )
  end

  defp section(_heading, []), do: nil

  defp section(heading, questions) do
    """
    #{heading} (#{length(questions)})

    #{Enum.map_join(questions, "\n", &render/1)}\
    """
  end

  defp render(%OpenQuestion{} = question) do
    """
      #{Enum.join(OpenQuestion.texts(question), "\n  ")}
        question: #{question.id}
        agent: #{question.agent_id} (#{question.agent_role}, #{question.agent_status})
        checkout: #{question.working_copy_id}#{root(question)}
        asked: #{question.asked_at}#{because(question)}
    """
  end

  defp root(%OpenQuestion{working_copy_root: nil}), do: ""
  defp root(%OpenQuestion{working_copy_root: root}), do: " #{root}"

  defp because(%OpenQuestion{escalation_reason: nil}), do: ""
  defp because(%OpenQuestion{escalation_reason: reason}), do: "\n    sent up because: #{reason}"
end
