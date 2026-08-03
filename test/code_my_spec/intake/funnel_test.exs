defmodule CodeMySpec.Intake.FunnelTest do
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Events
  alias CodeMySpec.Intake.Funnel

  describe "pre-gate steps" do
    test "each step of the flow is recorded against the plan" do
      plan_id = Ecto.UUID.generate()

      Funnel.plan_reached(:described, %{plan_id: plan_id})
      Funnel.plan_reached(:plan_shown, %{plan_id: plan_id})
      Funnel.plan_reached(:names_confirmed, %{plan_id: plan_id})

      assert Events.exists?("intake_described", plan_id: plan_id)
      assert Events.exists?("intake_plan_shown", plan_id: plan_id)
      assert Events.exists?("intake_names_confirmed", plan_id: plan_id)
    end

    test "steps are recorded per plan, so one visitor's progress is separable" do
      mine = Ecto.UUID.generate()
      theirs = Ecto.UUID.generate()

      Funnel.plan_reached(:described, %{plan_id: mine})
      Funnel.plan_reached(:plan_shown, %{plan_id: theirs})

      refute Events.exists?("intake_plan_shown", plan_id: mine)
      assert Events.exists?("intake_plan_shown", plan_id: theirs)
    end
  end
end
