defmodule CodeMySpec.Intake.PlansRepository do
  @moduledoc """
  Data access for intake plans. Plans are addressed by the anonymous
  session token — there is no scope, because there is no user yet.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Intake.Plan
  alias CodeMySpec.Repo

  @spec get_by_token(String.t()) :: Plan.t() | nil
  def get_by_token(session_token) when is_binary(session_token) do
    Repo.get_by(Plan, session_token: session_token)
  end

  @spec start(String.t()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def start(session_token) when is_binary(session_token) do
    session_token
    |> Plan.start_changeset()
    |> Repo.insert()
  end

  @spec update(Ecto.Changeset.t()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def update(%Ecto.Changeset{} = changeset) do
    Repo.update(changeset)
  end
end
