defmodule CodeMySpec.Provisioning.Transport do
  @moduledoc """
  Transport failures in words.

  Every probe in provisioning ends in the same handful of socket errors, and
  each layer wraps them differently: Req raises `%Req.TransportError{}`, Finch
  nests an identical `%Mint.TransportError{}` inside its own. The reason atom
  is the entire payload; everything around it is noise, and the setup page
  truncates the struct mid-word so the actionable half is what gets cut.

  This is deliberately a leaf module. `Steps` already calls `Deploy`, so the
  formatter cannot live in either without one of them depending on the other.
  """

  @doc """
  Describe a transport failure as a sentence fragment.

  Accepts a bare atom, any struct carrying a `:reason` atom (which covers Req,
  Finch and Mint alike), and an `{:error, reason}` tuple. Anything else is
  inspected, because a term nobody anticipated is better shown than guessed at.
  """
  @spec describe(term()) :: String.t()
  def describe({:error, reason}), do: describe(reason)
  def describe(%{reason: reason}) when is_atom(reason), do: describe(reason)
  def describe(reason) when is_binary(reason), do: reason

  def describe(:econnrefused), do: "nothing is listening on that port"
  def describe(:nxdomain), do: "the name does not resolve yet"
  def describe(:timeout), do: "the host did not answer in time"
  def describe(:ehostunreach), do: "the host is unreachable"
  def describe(:econnreset), do: "the host closed the connection"
  def describe(:closed), do: "the connection closed before an answer"

  # Still a word rather than a struct. An atom nobody has a sentence for reads
  # better as `econnaborted` than as `:econnaborted`, and the ones that matter
  # are named above.
  def describe(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  def describe(reason), do: inspect(reason, printable_limit: :infinity, limit: :infinity)
end
