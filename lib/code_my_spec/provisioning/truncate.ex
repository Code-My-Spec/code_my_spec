defmodule CodeMySpec.Provisioning.Truncate do
  @moduledoc """
  Keep both ends of a long message, not just one.

  Every truncation here used to pick one end and keep it — the tail, on the
  theory that apt/gem/SSHKit chatter buries the real cause first and its own
  conclusion last. That is true of some tools and false of others: Ruby's own
  convention is the opposite, an `ERROR: ...` line *before* its backtrace, not
  after. A single-ended slice is structurally wrong for whichever family of
  tool it was not written against — confirmed live, twice, in the same
  incident: `install_kamal/1`'s tail slice correctly surfaced a needrestart
  failure's real cause, and then surfaced nothing but backtrace frames for a
  `gem` crash that had already said what went wrong, one line up, outside the
  kept window.

  Keeping both ends costs nothing when a tool's useful line lands in either
  place, and only ever adds information relative to picking one.
  """

  @doc """
  `text`, or its first and last `div(budget, 2)` characters joined by a
  marker if longer than `budget`.
  """
  @spec head_and_tail(String.t(), pos_integer()) :: String.t()
  def head_and_tail(text, budget \\ 300) when is_binary(text) and budget > 0 do
    if String.length(text) <= budget do
      text
    else
      half = div(budget, 2)
      "#{String.slice(text, 0, half)}\n…\n#{String.slice(text, -half, half)}"
    end
  end
end
