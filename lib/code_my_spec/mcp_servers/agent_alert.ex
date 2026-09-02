defmodule CodeMySpec.McpServers.AgentAlert do
  @moduledoc """
  Puts the analyzer alert on what an agent's tool call answers.

  ## Why this exists beside the hook rather than inside it

  `Hooks.PostToolUse` already does this for an agent running under Claude Code:
  every tool call carries a line saying an analyzer run landed, so the agent
  finds out it broke something while it can still act on it. That is story
  1041's whole subject, and the incident behind it cost a database.

  It reaches exactly one kind of agent. Claude Code fires the hook; an agent
  running under Alloy fires none of the seven, so the delivery decision recorded
  on that story — "PostToolUse, on every tool call" — is true of the persona it
  was written for and silent for the other. Story 1042 is that gap, and this is
  its delivery.

  ## The message is not reinvented

  `Analysis.Alert.check/3` produces it, unchanged, for both. What differs
  is where it is attached: a hook response there, a tool result here. That is
  the whole of "same words, different transport", and it is why criterion 3045
  compares the two surfaces against one landing rather than asserting a fixed
  string — a second wording would be a second thing to keep true.

  ## Only for a caller that named itself

  `agent_id` is what makes this an agent's tool call rather than a person's at
  an MCP client. A human's call gets nothing appended: they are not in a turn,
  nothing is being driven by what they last edited, and a line about the tree on
  every call is noise to somebody who can look.

  Dedup is `Analysis.Alert`'s and stays there — per agent, so an agent is told
  once per landing however many tools it calls in a turn.
  """

  alias CodeMySpec.Analysis.Alert
  alias CodeMySpec.Users.Scope

  @doc """
  `text` with the alert appended, or `text` unchanged.

  Unchanged is the common answer and the cheap one: no agent named, nothing
  outstanding, or this agent already told about the findings as they stand.
  """
  @spec append(String.t(), Scope.t(), map()) :: String.t()
  def append(text, scope, params) when is_binary(text) do
    case alert(scope, params) do
      nil -> text
      alert -> text <> "\n\n" <> alert
    end
  end

  def append(text, _scope, _params), do: text

  defp alert(%Scope{} = scope, params) do
    case agent_id(params) do
      nil -> nil
      agent_id -> Alert.check(scope, nil, agent_id)
    end
  end

  defp alert(_scope, _params), do: nil

  # Accepts either key shape. Tool params arrive atom-keyed through Anubis and
  # string-keyed from anything that hands a map straight in, and a silently
  # missed agent id here reads as "the feature does not work" rather than as a
  # key mismatch.
  defp agent_id(%{agent_id: id}) when is_binary(id), do: id
  defp agent_id(%{"agent_id" => id}) when is_binary(id), do: id
  defp agent_id(_params), do: nil
end
