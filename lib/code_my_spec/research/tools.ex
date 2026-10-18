defmodule CodeMySpec.Research.Tools do
  @moduledoc """
  The web tools an agent calls.

  Both are gated on the caller's project scope: `web_fetch` makes the server
  fetch a URL somebody else chose (ungated, an open proxy), and `web_search`
  spends a key the operator pays for.
  """

  def all, do: [__MODULE__.WebSearch, __MODULE__.WebFetch]

  @doc "The caller's project scope, or the refusal an unscoped call gets."
  def scoped(context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> {:ok, scope}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
