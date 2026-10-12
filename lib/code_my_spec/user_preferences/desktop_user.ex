defmodule CodeMySpec.UserPreferences.DesktopUser do
  @moduledoc """
  The desktop build's one user: `<os user>@localhost`, put on every browser
  scope without a login.
  """

  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users

  def active?, do: Application.get_env(:code_my_spec, :env) == :desktop

  def email(os_user \\ System.get_env("USER") || System.get_env("USERNAME")) do
    case String.replace(os_user || "", ~r/[^A-Za-z0-9._-]/, "") do
      "" -> "user@localhost"
      local -> "#{String.downcase(local)}@localhost"
    end
  end

  @doc "The desktop user's scope; nil outside desktop or before first boot."
  def scope do
    if active?(), do: email() |> Users.get_user_by_email() |> UserPreferences.scope_for()
  end
end
