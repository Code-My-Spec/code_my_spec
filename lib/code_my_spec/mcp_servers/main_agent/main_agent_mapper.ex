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
  alias CodeMySpec.MainAgent
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

  @doc """
  An agent's turns, oldest first, and whether anything was cut.

  The truncation notice goes at the top rather than the bottom. A caller that
  reads far enough to reach a footer has already formed a view of what the agent
  did; the one fact that changes how to read the rest belongs before it.
  """
  @spec conversation(%{turns: [map()], truncated?: boolean()}) :: Response.t()
  # An empty answer to a *narrowed* read, before the empty-conversation clause.
  #
  # Both arrive as `turns: []` and they mean opposite things: one says there is
  # nothing to read, the other says there is plenty and none of it matched. The
  # agent reading this decides whether to look elsewhere on that basis, and it
  # was told the wrong one — agents with long histories were reported as having
  # said nothing because they had never called the tool asked about (`2a809b93`).
  def conversation(%{turns: [], no_match: {:last_call_of, tool}}) do
    Response.tool()
    |> Response.text("""
    This agent has never called `#{tool}`.

    Its conversation is not empty — it has taken turns, and none of them called \
    that tool. Read it without `last_call_of` to see what it did instead.\
    """)
  end

  def conversation(%{turns: [], no_match: :window}) do
    Response.tool()
    |> Response.text("""
    No turns fall inside that window.

    Its conversation is not empty — it has taken turns, and none of them are \
    within the `since`/`until` range asked for. Widen the range, or drop it to \
    read from the recent end.\
    """)
  end

  def conversation(%{turns: [], truncated?: _}) do
    Response.tool()
    |> Response.text("""
    This agent has said nothing yet.

    It exists and its conversation is empty — it has not taken a turn, rather \
    than having taken one that produced no output.\
    """)
  end

  def conversation(%{turns: turns, truncated?: truncated?}) do
    Response.tool()
    |> Response.text(notice(truncated?) <> Enum.map_join(turns, "\n", &MainAgent.turn_line/1))
  end

  defp notice(false), do: ""

  defp notice(true) do
    """
    This conversation was truncated — the oldest turns are not shown, and what \
    follows is the recent end of a longer conversation. Ask for a smaller \
    `limit` to read further back in pages.

    """
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

  def error(:no_agent_named) do
    Response.tool()
    |> Response.error("""
    Name an agent to read. Pass `agent_id` for one, or `agent_ids` for several \
    on one timeline. `list_agent_work` shows which agents this project has.\
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
