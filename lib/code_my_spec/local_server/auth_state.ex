defmodule CodeMySpec.LocalServer.AuthState do
  @moduledoc """
  Holds pending OAuth PKCE state between `/auth/start` and `/auth/callback`.

  Stores `{state, code_verifier, client_id, client_secret, redirect_uri}`
  keyed by the OAuth state parameter. Entries are cleaned up after callback.
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def store(state, data) do
    Agent.update(__MODULE__, &Map.put(&1, state, data))
  end

  def get(state) do
    Agent.get(__MODULE__, &Map.get(&1, state))
  end

  def delete(state) do
    Agent.update(__MODULE__, &Map.delete(&1, state))
  end
end
