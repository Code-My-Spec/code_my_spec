defmodule CodeMySpec.CodeMode.LuaValue do
  @moduledoc """
  Lua's table shape, converted to Elixir's — in both directions of a call.

  A Lua table arrives as a list of `{key, value}` pairs. Left alone it reaches
  a tool as `[{1, [{"name", "..."}]}]` and reaches the agent as
  `{54, [{"id", 962}]}` — the array index showing as a key, every record a list
  of pairs.

  ## Why one module and not two conversions

  This started as a private function on the return path, because that is where
  it was first noticed. The argument path needed exactly the same thing and did
  not have it, so any tool whose schema expects an array or a nested object
  could not be called from a script at all: validation rejected the pair list.
  `submit_qa_result` was the one that found it, which is a tool an agent calls
  once per QA session and could not call at all.

  Two copies of this would drift, and the drift would be invisible — a script
  that reads records but cannot send them looks like a schema problem, not a
  conversion one.

  ## Arrays and records

  Consecutive integer keys from 1 are a Lua array and become a list; anything
  else is a record and becomes a map with string keys. The keys are sorted
  before that decision and again on the way out, because a Lua table is a hash
  and its pairs arrive in whatever order the VM holds them — `[49, 75, 1, …]`
  for a plain array of 98 stories.
  """

  @doc "A decoded Lua value as plain Elixir data."
  @spec from_lua(term()) :: term()
  def from_lua([{_key, _value} | _rest] = table) do
    keys = Enum.map(table, &elem(&1, 0))

    if array?(keys),
      do: table |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&from_lua(elem(&1, 1))),
      else: Map.new(table, fn {key, value} -> {to_string(key), from_lua(value)} end)
  end

  # Lua has one number type, so every integer arrives as a float and a tool
  # expecting an integer id rejects `970.0`. Only exact integers convert; a
  # genuine fraction is left alone rather than quietly truncated.
  def from_lua(value) when is_float(value) do
    case trunc(value) do
      whole when whole == value -> whole
      _otherwise -> value
    end
  end

  def from_lua(value), do: value

  defp array?([]), do: false
  defp array?(keys), do: Enum.sort(keys) == Enum.to_list(1..length(keys)//1)
end
