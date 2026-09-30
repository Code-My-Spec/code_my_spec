defmodule CodeMySpec.Agents.TurnTimeout do
  @moduledoc """
  A failed turn, read for the provider's CLI running out of time (eb09b076).

  Read off the transcript's text, like `ProviderRefusal`: a failed turn is
  written as the provider's error line and nothing else marks it.
  """

  @timed_out ~r/^(\w+ exec) timed out after \d+ms/

  @type streak :: %{count: pos_integer(), exec: String.t()}

  @doc "The CLI that timed out (`\"claude exec\"`), or nil when the text is not a timeout."
  @spec exec(String.t() | nil) :: String.t() | nil
  def exec(text) when is_binary(text) do
    case Regex.run(@timed_out, text) do
      [_, exec] -> exec
      nil -> nil
    end
  end

  def exec(_text), do: nil

  @doc """
  The run of timed-out turns an agent's latest messages end on, or nil.

  `texts` is what the agent wrote, newest first. Anything else it wrote — a
  step, a reply, another failure — ends the run.
  """
  @spec streak([String.t() | nil]) :: streak() | nil
  def streak(texts) do
    case Enum.take_while(texts, &exec/1) do
      [] -> nil
      [latest | _] = run -> %{count: length(run), exec: exec(latest)}
    end
  end
end
