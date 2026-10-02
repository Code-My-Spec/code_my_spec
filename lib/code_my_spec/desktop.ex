defmodule CodeMySpec.Desktop do
  @moduledoc """
  The desktop build's one user (bb8bc042): `<os user>@localhost`, put on every
  browser scope without a login.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.UserPreferences, CodeMySpec.Users],
    exports: :all

  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users

  def active?, do: Application.get_env(:code_my_spec, :env) == :desktop

  def email(os_user \\ System.get_env("USER") || System.get_env("USERNAME")) do
    case String.replace(os_user || "", ~r/[^A-Za-z0-9._-]/, "") do
      "" -> "user@localhost"
      local -> "#{String.downcase(local)}@localhost"
    end
  end

  def scope, do: email() |> Users.get_user_by_email() |> UserPreferences.scope_for()
end
