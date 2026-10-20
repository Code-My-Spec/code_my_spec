defmodule CodeMySpecWeb.Format do
  @moduledoc "Numbers the way a glance reads them."

  @doc """
  A count in a few characters: `999`, then `1.23k`, `12.3k`, `123k`, then
  `1.23m` and on through `b` — two decimals under ten, one under a hundred,
  none above, with trailing zeros dropped.
  """
  @spec compact(integer()) :: String.t()
  def compact(n) when is_integer(n) and n < 1_000, do: Integer.to_string(n)
  def compact(n) when is_integer(n) and n < 1_000_000, do: scaled(n / 1_000, "k")
  def compact(n) when is_integer(n) and n < 1_000_000_000, do: scaled(n / 1_000_000, "m")
  def compact(n) when is_integer(n), do: scaled(n / 1_000_000_000, "b")

  defp scaled(value, unit) do
    decimals =
      cond do
        value < 10 -> 2
        value < 100 -> 1
        true -> 0
      end

    factor = Integer.pow(10, decimals)
    truncated = trunc(value * factor) / factor

    text =
      truncated
      |> :erlang.float_to_binary(decimals: decimals)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

    text <> unit
  end
end
