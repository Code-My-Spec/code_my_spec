defmodule CmsHarnessTest.ConnectHeaders do
  @moduledoc """
  The headers a served working copy's socket connects with, per root.

  Named by `config :code_my_spec, :harness_connect_headers` in test, and read by
  `CmsHarness.Config.connect_headers/1` when a copy's `ChannelClient` dials. A
  test puts its SQL sandbox metadata here as the copy's `user-agent`, so the
  cloud's `UserSocket` lets that copy's channel use that test's connection —
  which is what lets two copies served at once by one node, in two async tests,
  each see only their own data.

  Keyed on the root, so nothing global changes when a test sets one.
  """

  @doc "Connect `root`'s socket with `user_agent` until `delete/1`."
  @spec put(String.t(), String.t()) :: :ok
  def put(root, user_agent), do: :persistent_term.put(key(root), user_agent)

  @doc "Forget `root`'s headers."
  @spec delete(String.t()) :: :ok
  def delete(root) do
    :persistent_term.erase(key(root))
    :ok
  end

  @doc "The headers `root`'s socket connects with; none for a root nobody set."
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(root) do
    case :persistent_term.get(key(root), nil) do
      nil -> []
      user_agent -> [{"user-agent", user_agent}]
    end
  end

  defp key(root), do: {__MODULE__, Path.expand(root)}
end
