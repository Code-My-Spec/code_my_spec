defmodule CodeMySpec.Intake.PlansRepository do
  @moduledoc """
  Data access for intake plans. Plans are addressed by the anonymous
  session token — there is no scope, because there is no user yet.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Intake.Plan
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies.WorkingCopy

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

  @doc """
  The most recent plans, newest first.

  For the dev route that hands QA a session token. The token is minted into the
  Phoenix session by `Plugs.IntakeSession` and signed, so somebody driving a
  browser has no way to read the one they are holding — which made every
  per-session intake seam unreachable from outside the application. They open
  `/build`, find the plan they just started here, and address it by its token.
  """
  @spec recent(pos_integer()) :: [Plan.t()]
  def recent(limit) when is_integer(limit) and limit > 0 do
    Repo.all(from p in Plan, order_by: [desc: p.inserted_at, desc: p.id], limit: ^limit)
  end

  @doc """
  Converted plans, chosen `location: :local`, whose project has no checkout
  yet.

  "No checkout yet" is derived rather than flagged — a plan needs no
  `claimed`/`pending` column of its own, because the instant a harness mints
  this project a working copy (`mix harness.onboard`), it stops matching this
  query on its own. Nothing has to mark it done.
  """
  @spec pending_local(Ecto.UUID.t()) :: [Plan.t()]
  def pending_local(account_id) when is_binary(account_id) do
    Repo.all(
      from p in Plan,
        as: :plan,
        where: p.account_id == ^account_id,
        where: p.status == :converted,
        where: p.location == :local,
        where: not is_nil(p.project_id),
        where:
          not exists(from wc in WorkingCopy, where: wc.project_id == parent_as(:plan).project_id),
        preload: [:project]
    )
  end
end
