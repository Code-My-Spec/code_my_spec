defmodule CodeMySpec.Utils.MapAccess do
  @moduledoc """
  Reading a field whose key type isn't guaranteed.

  Several maps in this codebase cross a boundary that doesn't fix their key
  type — some producers build them atom-keyed in Elixir, others decode them
  from JSON and leave string keys — so a reader that assumes one guesses
  wrong for the other. The map[:k] || map["k"] pattern that grew up around
  this checks both, but repeated at every call site it's easy to typo one
  side and easy for `mix credo` (ExSlop's `DualKeyAccess`) to flag as
  defensive coding that should normalize once instead.

  `get/3` is that one normalization, named so a caller states the field
  instead of restating the ambiguity.
  """

  @doc "The value for `key` (an atom), trying `key` then `to_string(key)`, or `default`."
  @spec get(map(), atom(), term()) :: term()
  def get(map, key, default \\ nil) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end
end
