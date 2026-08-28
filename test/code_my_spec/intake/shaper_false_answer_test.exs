defmodule CodeMySpec.Intake.ShaperFalseAnswerTest do
  @moduledoc """
  `false` from the model is an answer, not a missing one.

  Two of the four fields the shaper asks for are booleans: whether people sign
  in, and whether each business runs its own copy. The mapping from the model's
  object to changeset attrs read `object[string_key] || object[atom_key]`, so a
  model answering `false` hit the `||`, fell through to a key that was not
  there, and produced `nil`. `answers_changeset/2` rejects that as blank, and
  the visitor was told the model could not think it through.

  It therefore failed on exactly the ideas that answer no — one business's own
  tool, nobody signs in — and deterministically, while a multi-tenant idea
  sailed through. Reported from production as "an ai mahjong coach" failing
  where "a booking tool for hair salons" worked, which reads as the model being
  unreliable rather than as `false` being dropped on the way to the changeset.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.Plan
  alias CodeMySpec.Intake.Shaper.Llm

  # The shape a provider actually returns: string keys, and `false` for no.
  @object %{
    "question" => "",
    "needs_sign_in" => false,
    "separate_copies" => false,
    "who_uses" => "beginners learning mahjong"
  }

  test "a model that answers no is not read as a model that said nothing" do
    attrs = Llm.to_attrs_for_test(@object)

    assert attrs[:needs_sign_in] == false,
           "`false` came back as #{inspect(attrs[:needs_sign_in])}. Two of these " <>
             "fields are booleans, and `||` cannot tell a false answer from a " <>
             "missing key."

    assert attrs[:separate_copies] == false
    assert attrs[:who_uses] == "beginners learning mahjong"
  end

  test "and the plan those answers belong to saves" do
    attrs = Llm.to_attrs_for_test(@object)

    {:ok, plan} = Intake.start_plan(Intake.new_session_token())
    {:ok, plan} = Intake.describe(plan, "a mahjong game with an ai coach for beginners")

    assert {:ok, %Plan{} = saved} = Intake.answer(plan, attrs),
           "the plan would not save, so the visitor is told the model could not " <>
             "think it through — on exactly the ideas that answer no, every time."

    refute saved.needs_sign_in
    refute saved.separate_copies
  end

  test "a plan arriving ends the call, so nothing keeps saying Thinking" do
    attrs = Llm.to_attrs_for_test(@object)

    {:ok, plan} = Intake.start_plan(Intake.new_session_token())
    {:ok, plan} = Intake.describe(plan, "a mahjong game with an ai coach for beginners")
    {:ok, plan} = Intake.answer(plan, attrs)

    {:ok, thinking} = Intake.shape_async(plan, __MODULE__.AlwaysPlans)

    assert thinking.shaping_status == :idle,
           "the plan was written and the row still says a call is out, so every " <>
             "viewer keeps a Thinking bubble under a finished plan card. Only the " <>
             "question path cleared it."
  end
end

defmodule CodeMySpec.Intake.ShaperFalseAnswerTest.AlwaysPlans do
  @moduledoc false
  @behaviour CodeMySpec.Intake.Shaper

  @impl true
  def shape(_plan, _turns),
    do: {:ok, %{needs_sign_in: false, separate_copies: false, who_uses: "beginners"}}

  @impl true
  def conclude(_plan, _turns),
    do: {:ok, %{needs_sign_in: false, separate_copies: false, who_uses: "beginners"}}
end
