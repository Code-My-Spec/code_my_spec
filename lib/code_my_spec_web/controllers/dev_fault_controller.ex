defmodule CodeMySpecWeb.DevFaultController do
  @moduledoc """
  Break one caller's world, from a terminal, in development.

  Issue `0fb7bf03`: nine criteria across five stories are about what the system
  does when something underneath it breaks, and every one of them was blocked,
  because the only seams were node-global. Flipping
  `:main_agent_digest_source` breaks every project's digest on a box four other
  checkouts share; swapping `CodeMySpec.Intake[:shaper]` breaks every visitor's
  intake for as long as it is swapped. Five QA agents in a row reached the same
  refusal independently, which is the cost this exists to end.

      GET    /dev/faults                         what is injected, and what can be
      POST   /dev/faults   {"key": …, "fault": …}
      DELETE /dev/faults   {"key": …, "fault": …}   or {"all": true}
      GET    /dev/intake/plans                   recent plans, to find a key

  `key` is whatever the seam already carries — see `CodeMySpec.Faults`. Today
  that is a project id for `digest_unavailable` and an intake plan's
  `session_token` for `intake_shaper_fails`.

  That last one needs the extra route: the token is minted into the Phoenix
  session by `Plugs.IntakeSession` and signed, so a visitor driving a browser
  cannot read the one they are holding. Open `/build`, list the plans, and the
  one you just started is at the top.

  Behind `:dev_routes`, which is compile-time: absent from the release rather
  than disabled in it, because a route that makes the product fail on demand is
  exactly the thing that must not ship by accident. It is also the only writer
  `CodeMySpec.Faults` has, so in production that table stays empty.

  ## Put it back

  Faults outlive the request and do not expire — a fault on a clock would clear
  itself mid-observation, which is the one behaviour that makes a seam worse
  than no seam. They die with the server, so a restart is the backstop, and
  `{"all": true}` is the deliberate one.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Faults
  alias CodeMySpec.Intake

  @doc """
  Recent intake plans, newest first, with the token that addresses one.

  The description comes back so the caller can recognise its own plan by words
  it chose, rather than trusting that the newest row is theirs — which on a box
  several people share is a guess.
  """
  def plans(conn, _params) do
    plans =
      Enum.map(Intake.recent_plans(), fn plan ->
        %{
          id: plan.id,
          session_token: plan.session_token,
          status: plan.status,
          shaping_status: plan.shaping_status,
          description: plan.description,
          started_at: plan.inserted_at
        }
      end)

    json(conn, %{plans: plans})
  end

  def index(conn, _params) do
    json(conn, %{
      injected: Faults.list(),
      available: Enum.map(Faults.known(), fn {name, what} -> %{fault: name, does: what} end)
    })
  end

  def create(conn, %{"key" => key, "fault" => fault}) when is_binary(key) and key != "" do
    case Faults.inject(key, fault_named(fault)) do
      :ok ->
        json(conn, %{status: "injected", key: key, fault: fault})

      {:error, {:unknown_fault, known}} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "nothing checks for a fault called #{inspect(fault)}",
          known: known,
          hint: "a fault nothing reads would never fire and would read as a pass"
        })
    end
  end

  def create(conn, _params) do
    conn |> put_status(422) |> json(%{error: ~s(both "key" and "fault" are required)})
  end

  def delete(conn, %{"all" => true}) do
    json(conn, %{status: "cleared", removed: Faults.clear_all()})
  end

  def delete(conn, %{"key" => key, "fault" => fault}) when is_binary(key) do
    :ok = Faults.clear(key, fault_named(fault))
    json(conn, %{status: "cleared", key: key, fault: fault})
  end

  def delete(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: ~s(give "key" and "fault", or "all": true)})
  end

  # Resolved against what exists rather than converted. An unknown name has to
  # reach `inject/2` to be refused with the list of real ones, and turning a
  # request body into an atom to carry that message is how an HTTP route becomes
  # a way to fill the atom table.
  defp fault_named(fault) when is_binary(fault) do
    Faults.known()
    |> Map.keys()
    |> Enum.find(:no_such_fault, &(Atom.to_string(&1) == fault))
  end

  defp fault_named(_fault), do: :no_such_fault
end
