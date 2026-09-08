defmodule CodeMySpec.Intake.Shaper do
  @moduledoc """
  Works out what to build from a short conversation, rather than asking.

  Sign-in and separate copies pick the auth and multitenancy generators. They
  are our questions, not the visitor's — someone with an idea for a booking
  tool has no view on tenancy and should not be asked to have one. So the
  model asks what a person would ask, and infers the rest.

  "A booking tool for hair salons, my clients book slots" already answers both:
  clients booking means sign-in, one salon means one copy. Asking anyway is how
  a form thinks.

  At most two questions. This runs before the visitor has given us anything —
  no email, no account — so every question spends goodwill we have not earned
  yet, and the third one is where people leave.
  """

  alias CodeMySpec.Intake.Plan

  @max_questions 2

  @doc "The visitor's answer to a question we asked."
  @type turn :: %{question: String.t(), answer: String.t()}

  @callback shape(Plan.t(), [turn()]) ::
              {:ask, String.t()} | {:ok, map()} | {:error, term()}

  @doc "Fill the form from what was said, whatever that was. Never asks."
  @callback conclude(Plan.t(), [turn()]) :: {:ok, map()} | {:error, term()}

  @doc """
  Either the next question worth asking, or what we now know.

  `{:ask, question}` while the model still wants something and the budget
  allows. At the cap the model does not get a say: an intake that keeps asking
  is worse than one that guesses and shows its guess, and the guess is
  correctable on the next screen.
  """
  @spec shape(Plan.t(), [turn()]) :: {:ask, String.t()} | {:ok, map()} | {:error, term()}
  def shape(%Plan{} = plan, turns) when length(turns) >= @max_questions do
    impl().conclude(plan, turns)
  end

  def shape(%Plan{} = plan, turns) do
    impl().shape(plan, turns)
  end

  @doc "How many questions this conversation may spend."
  @spec max_questions() :: pos_integer()
  def max_questions, do: @max_questions

  defp impl do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Intake, [])
    |> Keyword.get(:shaper, CodeMySpec.Intake.Shaper.Llm)
  end
end
