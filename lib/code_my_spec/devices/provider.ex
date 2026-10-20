defmodule CodeMySpec.Devices.Provider do
  @moduledoc """
  Where a dev box runs: its label, the kind of machine it is, and what Sam is
  shown to bring it up with the token it was just given (story 1130).

  A provider is one module with this behaviour, and `all/0` lists them. Adding
  one is a module and a line there; nothing about the others changes.
  """

  alias CodeMySpec.Devices.Providers

  @type section :: %{
          required(:key) => String.t(),
          required(:copy) => String.t(),
          required(:title) => String.t(),
          required(:body) => String.t()
        }

  @doc "The provider's id, as stored on the device and posted by the add form."
  @callback id() :: atom()

  @doc "What Sam picks it by."
  @callback label() :: String.t()

  @doc "`:local` or `:cloud`: the kind of machine a box from this provider is."
  @callback kind() :: :local | :cloud

  @doc """
  What to show with the token of a box just added: sections, each with a copy
  button. `context` carries the `:token` and this server's `:server_url`.
  """
  @callback instructions(context :: %{token: String.t(), server_url: String.t()}) :: [section()]

  @spec all() :: [module()]
  def all, do: [Providers.Local, Providers.ClaudeCodeCloud]

  @spec ids() :: [atom()]
  def ids, do: Enum.map(all(), & &1.id())

  @doc "The provider module for an id (atom or string), or nil."
  @spec get(atom() | String.t() | nil) :: module() | nil
  def get(id), do: Enum.find(all(), &(to_string(&1.id()) == to_string(id)))
end
