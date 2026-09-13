defmodule CodeMySpec.Intake.AnAcceptedDefaultIsStillAWriteTest do
  @moduledoc """
  Confirming the plan without touching the location select writes the location.

  Issue `3a3ea063`. `names_changeset/2` applied the cloud default by mutating
  the changeset's `data` before casting, so when the visitor submitted the
  default they had been shown — cloud, this story's own primary CTA, so almost
  everyone — the casted value equalled `data` and Ecto recorded no change. The
  UPDATE went out without `location`, the column stayed NULL, and
  `validate_required/2` passed anyway because `get_field/2` reads the mutated
  data. A write that silently did nothing and reported success.

  The visitor's symptom was the part worth testing for. `transcript/3` will only
  append "Call it Acme — the project is Salon Book" once the location is not
  nil, so on the next read of the row the confirmation turn and the signup card
  both disappeared and the visitor was asked to name a project they had just
  named.

  So the assertion is on the persisted row and on the transcript, not on the
  changeset — a changeset assertion would have passed throughout.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.Plan

  defp a_plan_at_the_names_card do
    {:ok, plan} = Intake.start_plan("token-#{System.unique_integer([:positive])}")
    {:ok, plan} = Intake.describe(plan, "a booking tool for a two-chair barbershop")

    plan
  end

  defp confirmed(plan, attrs) do
    {:ok, _} = Intake.confirm_names(plan, attrs)
    Intake.get_plan(plan.session_token)
  end

  describe "accepting the default the card showed" do
    test "records it, rather than reporting a write it did not make" do
      plan = a_plan_at_the_names_card()
      assert plan.location == nil, "the premise failed: this plan was already located"

      reread =
        confirmed(plan, %{
          "account_name" => "Acme",
          "project_name" => "Salon Book",
          "needs_sign_in" => "true",
          "separate_copies" => "false",
          "location" => "cloud"
        })

      assert reread.location == :cloud, """
      The row still says nothing about where this is going, and the visitor was
      told it worked. Everything downstream that asks reads NULL.
      """
    end

    test "so the confirmation survives a reload", %{} do
      plan = a_plan_at_the_names_card()

      reread =
        confirmed(plan, %{
          "account_name" => "Acme",
          "project_name" => "Salon Book",
          "needs_sign_in" => "true",
          "separate_copies" => "false",
          "location" => "cloud"
        })

      said = reread |> Intake.transcript() |> Enum.map_join("\n", & &1.text)

      assert said =~ "Acme", """
      The names the visitor just confirmed are not in the transcript read back
      off the row. On the page this is the confirmation turn and the signup card
      vanishing, and the visitor being asked to name a project they have named.

      Transcript was:
      #{said}
      """

      assert said =~ "Salon Book"
    end
  end

  describe "choosing the other one" do
    test "is recorded as what they chose" do
      plan = a_plan_at_the_names_card()

      reread =
        confirmed(plan, %{
          "account_name" => "Acme",
          "project_name" => "Salon Book",
          "needs_sign_in" => "true",
          "separate_copies" => "false",
          "location" => "local"
        })

      assert reread.location == :local,
             "the default overrode the visitor, which is worse than dropping it"
    end
  end

  describe "a plan nobody has confirmed" do
    test "still reads as never asked" do
      plan = a_plan_at_the_names_card()

      assert plan.location == nil, """
      The default reached the column without the visitor ever seeing the card.
      "Cloud because they chose it" and "cloud because nobody asked" have to
      stay different answers — the second is what an abandoned plan is.
      """
    end

    test "and the form still opens on cloud" do
      plan = a_plan_at_the_names_card()

      changeset = Intake.change_names(plan)

      assert Ecto.Changeset.get_field(changeset, :location) == :cloud, """
      The select opens empty, so the visitor has to discover a choice rather
      than see one already made. That is what the default is for, and it has to
      keep working now that it is a change rather than a mutation of the data.
      """
    end
  end
end
