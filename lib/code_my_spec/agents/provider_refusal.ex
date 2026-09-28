defmodule CodeMySpec.Agents.ProviderRefusal do
  @moduledoc """
  A failed turn, read for the provider refusing to run it.

  Issue 044599cc: an exhausted codex account left every agent reading as
  running for hours, while the provider's text said exactly what was wrong and
  when it would stop being wrong. This keeps that text and the retry time it
  names, so an agent can be *in* the state rather than an operator inferring it
  from timestamps that stopped moving.

  Only refusals — usage, quota, auth, a model the account cannot use. A crashed
  binary or a timeout is a failed turn, not the provider saying no.
  """

  @refusal ~r/usage limit|quota|rate[ _-]?limit|credits|billing|unauthori[sz]ed|authenticat|api key|forbidden|\b(401|403|429)\b|model\b.*\b(not found|not available|not supported|does not exist|unavailable)\b/i

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  @type t :: %{provider_refusal: String.t(), provider_retry_at: DateTime.t() | nil}

  @doc """
  The refusal in a failed turn's text, or nil when the text is not one.

  The reason is the provider's `ERROR:` line when the text carries one. The
  retry time is read from "try again at <date>" or "try again in <n> <unit>";
  a date the provider printed without a zone is taken as UTC.
  """
  @spec read(String.t() | nil, DateTime.t()) :: t() | nil
  def read(text, %DateTime{} = now) when is_binary(text) do
    if Regex.match?(@refusal, text) do
      %{provider_refusal: reason(text), provider_retry_at: retry_at(text, now)}
    end
  end

  def read(_text, _now), do: nil

  defp reason(text) do
    case Regex.run(~r/\bERROR:\s*(.+)/is, text) do
      [_, error] -> String.trim(error)
      nil -> String.trim(text)
    end
  end

  defp retry_at(text, now) do
    absolute(text) || relative(text, now)
  end

  defp absolute(text) do
    with [_, month, day, year, hour, minute | meridiem] <-
           Regex.run(
             ~r/try again (?:at|after) ([a-z]{3})[a-z]*\.? (\d{1,2})(?:st|nd|rd|th)?,? (\d{4}),? (?:at )?(\d{1,2}):(\d{2})\s*(am|pm)?/i,
             text
           ),
         month when is_integer(month) <-
           Enum.find_index(@months, &(&1 == String.downcase(month))),
         {:ok, date} <-
           Date.new(String.to_integer(year), month + 1, String.to_integer(day)),
         {:ok, time} <-
           Time.new(
             hour24(String.to_integer(hour), meridiem |> List.first("") |> String.downcase()),
             String.to_integer(minute),
             0,
             {0, 6}
           ) do
      DateTime.new!(date, time, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp hour24(12, "am"), do: 0
  defp hour24(hour, "pm") when hour < 12, do: hour + 12
  defp hour24(hour, _meridiem), do: hour

  defp relative(text, now) do
    case Regex.run(
           ~r/(?:try again|retry)(?: after| in) (\d+)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b/i,
           text
         ) do
      [_, n, unit] -> DateTime.add(now, String.to_integer(n) * seconds(unit), :second)
      nil -> nil
    end
  end

  defp seconds(unit) do
    case String.downcase(unit) do
      "h" <> _ -> 3600
      "m" <> _ -> 60
      _ -> 1
    end
  end
end
