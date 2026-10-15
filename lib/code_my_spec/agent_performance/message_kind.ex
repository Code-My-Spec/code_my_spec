defmodule CodeMySpec.AgentPerformance.MessageKind do
  @moduledoc """
  What an `:operator`-role message to an agent was: a message from a person or
  main, a restart, or one of the system's own notices.

  Every delivery used to record its sender as `"operator"`, so a message and an
  offer or analysis result were the same row (2026-10-14). The notices follow
  fixed templates, so they are told apart by their opening text; whatever
  matches none is counted as a message. Approximate by design -- John asked for
  something to look at, not an audit.
  """

  @type t ::
          :message
          | :restart
          | :work_offer
          | :analysis
          | :check_in
          | :turn_end
          | :harness_restart
          | :failed_turn
          | :promotion
          | :problems
          | :team_free
          | :offer_notice
          | :unblocked

  @templates [
    {~r/^Eligible work is available/, :work_offer},
    {~r/^Your (exunit|spex|compiler|credo|\w+) run finished/, :analysis},
    {~r/^Check-in/, :check_in},
    {~r/^Your turn is done/, :turn_end},
    {~r/^(The harness restarted|Your last turn ended without finishing)/, :harness_restart},
    {~r/^Your last turn failed/, :failed_turn},
    {~r/^Fix these problems before stopping/, :problems},
    {~r/^Working copy \S+ team is free/, :team_free},
    {~r/^(Offer declined by agent|Held back from)/, :offer_notice},
    {~r/^Your promotion of/, :promotion},
    {~r/^Your blocker was released/, :unblocked},
    {~r/^Your request to leave the loop was declined/, :turn_end},
    {~r/^Restarted:/, :restart}
  ]

  @doc "The kind of one message, from its sender and text."
  @spec of(String.t() | nil, String.t()) :: t()
  def of("system:restart", _text), do: :restart
  def of("promotion-notice", _text), do: :promotion

  def of(_sender, text) do
    trimmed = String.trim_leading(text)

    Enum.find_value(@templates, :message, fn {pattern, kind} ->
      Regex.match?(pattern, trimmed) && kind
    end)
  end

  @doc "Kinds that count as a person or main stepping in: a message or a restart."
  @spec intervention?(t()) :: boolean()
  def intervention?(kind), do: kind in [:message, :restart]
end
