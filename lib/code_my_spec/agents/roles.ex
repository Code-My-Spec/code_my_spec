defmodule CodeMySpec.Agents.Roles do
  @moduledoc """
  The roles an agent can hold.

  A module of its own, depending on nothing, so a schema can use the list as
  `Ecto.Enum` values at compile time without that compile-time dependency
  reaching everything `Agent` reaches. `ModelSetting` read it through
  `Agent.roles/0`, which put it in the app's compile cycle.
  """

  @roles [:main, :product, :coding, :qa]

  @doc "Every role, in order."
  def all, do: @roles
end
