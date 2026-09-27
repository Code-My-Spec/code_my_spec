defmodule CmsHarness.Project.DraftBuffer do
  @moduledoc """
  What each agent is writing, gathered from `:text_delta` fragments into the
  `agent_draft` payloads that go on the wire.

  A payload is the whole draft so far, never a fragment: a view that misses one
  is corrected by the next instead of showing a sentence with a hole in it.

  Pure, so the wire shape has one definition. `ChannelClient` flushes it on a
  timer; a criterion relaying over a test channel flushes it on every fragment.
  Two versions of a wire shape is one that drifts.
  """

  @type draft :: %{turn: term(), text: String.t(), dirty: boolean()}
  @type t :: %{String.t() => draft()}

  # What was being drafted has been said, or never will be.
  @settling_events [:message, :turn_ended, :turn_failed, :turn_cut_off]

  @spec new() :: t()
  def new, do: %{}

  @doc """
  One fragment. A new `turn` is a new model call, so a new draft — Alloy counts
  turns from 1 again on every run, which is why `settle/3` has to clear a
  finished one rather than leave it for the next run's turn 1 to append to.
  """
  @spec add(t(), String.t(), term(), String.t()) :: t()
  def add(buffer, agent_id, turn, text) do
    draft =
      case buffer do
        %{^agent_id => %{turn: ^turn, text: so_far}} -> %{turn: turn, text: so_far <> text}
        _ -> %{turn: turn, text: text}
      end

    Map.put(buffer, agent_id, Map.put(draft, :dirty, true))
  end

  @doc "Drop an agent's draft when a turn event means it is over."
  @spec settle(t(), String.t(), atom()) :: t()
  def settle(buffer, agent_id, event) when event in @settling_events,
    do: Map.delete(buffer, agent_id)

  def settle(buffer, _agent_id, _event), do: buffer

  @doc "The payloads for every draft that changed since the last take."
  @spec take(t()) :: {[map()], t()}
  def take(buffer) do
    Enum.reduce(buffer, {[], buffer}, fn
      {agent_id, %{dirty: true} = draft}, {payloads, buffer} ->
        {[payload(agent_id, draft) | payloads],
         Map.put(buffer, agent_id, %{draft | dirty: false})}

      _clean, acc ->
        acc
    end)
  end

  defp payload(agent_id, draft),
    do: %{"agent_id" => agent_id, "turn" => draft.turn, "text" => draft.text}
end
