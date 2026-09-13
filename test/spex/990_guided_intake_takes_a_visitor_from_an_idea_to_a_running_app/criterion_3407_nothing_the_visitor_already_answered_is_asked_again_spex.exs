defmodule CodeMySpecSpex.Story990.Criterion3407Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 3407 — Nothing the visitor already answered is asked again.

  Rule: the interview's first question is written with the shaping
  conversation already in hand, not from a blank slate.

  Like 990/3403, this is the model's judgment, not a deterministic branch —
  `Interviewer.Scripted` (what every other spex in this story runs against)
  asks a fixed list regardless of what came before, so it cannot exhibit this
  rule either way. `Interviewer.Llm.ask/2` is given the plan's `description`
  and `summary` in its prompt, along with an explicit instruction not to
  repeat anything already asked or answered — this proves a real model
  actually honours that once the shaping half of the conversation has settled
  sign-in and tenancy in plain terms.

  ## Recording

  `@mode` below is `:replay`. To re-record against a live model:

      1. Flip `@mode` to `:record`.
      2. `rm test/cassettes/intake/interview_recalls_intake_answers.json`
      3. `MIX_ENV=test elixir -S mix spex --pattern \
         "test/spex/990_*/criterion_3407*"`
      4. Read what the model actually asked and update the `then_` assertion
         if the real wording needs a different anchor than "sign in".
      5. Flip `@mode` back to `:replay` and re-run to confirm replay is clean.
      6. Commit the cassette alongside this file.

  Swaps `:shaper` and `:interviewer` to the real `CodeMySpec.Intake.Shaper.Llm`
  / `Interviewer.Llm` for this file only, and pins `:planner` to
  `Planner.Inferred` deliberately — a real Anthropic key configured for the
  shaper makes `Planner.impl/0` pick `Planner.Llm` too unless told otherwise,
  and this scenario has no business paying for or depending on a real plan;
  only the interview's question is under test.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  @mode :replay
  @cassette_dir "test/cassettes/intake"
  @cassette_name "interview_recalls_intake_answers"
  @model "anthropic:claude-sonnet-5"

  # Answered plainly enough that a model reading it back has no real
  # ambiguity left about sign-in or tenancy — the two things this criterion
  # says must not be asked again once the interview starts.
  @description "a booking tool for hair salons"
  @answer "Each client logs into their own account to book a slot, and it's " <>
            "just my one salon — no separate businesses."

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)
    :ok
  end

  setup do
    previous_intake = Application.get_env(:code_my_spec, CodeMySpec.Intake, [])
    previous_key = Application.get_env(:req_llm, :anthropic_api_key)

    # Shared (Agent-based), not local/process-dict: the shaper's calls run
    # inside the /build LiveView's process and the interview's inside
    # /build/workspace's — two different processes, so a process-dict
    # session (each starting its own count at 0) served the interview call
    # the shaper's first cassette interaction back.
    cassette_path = Path.join(@cassette_dir, @cassette_name <> ".json")
    shared_session = ReqCassette.Session.start_shared_session()
    session_id = ReqCassette.Session.start_session(cassette_path, shared_session)

    plug =
      {ReqCassette.Plug,
       %{
         cassette_name: @cassette_name,
         cassette_dir: @cassette_dir,
         mode: @mode,
         sequential: true,
         match_requests_on: [:method, :uri],
         filter_sensitive_data: [],
         filter_request_headers: ["authorization", "x-api-key"],
         filter_response_headers: ["set-cookie", "request-id"],
         filter_request: nil,
         filter_response: nil,
         before_record: nil,
         template: nil,
         session_id: session_id,
         req_options: []
       }}

    Application.put_env(:code_my_spec, CodeMySpec.Intake,
      shaper: CodeMySpec.Intake.Shaper.Llm,
      interviewer: CodeMySpec.Intake.Interviewer.Llm,
      planner: CodeMySpec.Intake.Planner.Inferred,
      model: @model,
      req_options: [plug: plug]
    )

    Application.put_env(:req_llm, :anthropic_api_key, anthropic_key(@mode))

    on_exit(fn ->
      ReqCassette.Session.end_session(cassette_path, session_id)
      ReqCassette.Session.end_shared_session(shared_session)
      Application.put_env(:code_my_spec, CodeMySpec.Intake, previous_intake)
      restore_anthropic_key(previous_key)
    end)

    :ok
  end

  defp restore_anthropic_key(nil), do: Application.delete_env(:req_llm, :anthropic_api_key)
  defp restore_anthropic_key(value), do: Application.put_env(:req_llm, :anthropic_api_key, value)

  defp anthropic_key(:replay), do: "replayed-key"

  defp anthropic_key(:record) do
    System.get_env("ANTHROPIC_API_KEY") ||
      flunk("no Anthropic key. Set ANTHROPIC_API_KEY to re-record.")
  end

  spex "The interview's first question is written with the shaping answers already in hand" do
    scenario "Nothing the visitor already answered is asked again" do
      given_ "a visitor who described their idea and answered the shaping questions",
            context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, @description)
        answer_shaping_questions(view, [@answer])

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "their project comes up and they say something to its agent", context do
        to = confirm_plan(context.view, %{location: "cloud"})

        assert to == "/build/workspace",
               "expected a signed-in visitor to be sent to their workspace, got #{inspect(to)}"

        {:ok, workspace_view, _html} = live(context.conn, to)

        # Cloud now pays before it provisions (990/3400) — not this
        # criterion's subject, so cleared the way the browser's own Stripe
        # hook would, to reach the interview this scenario is about.
        html = render_hook(workspace_view, "payment_confirmed", %{})

        {:ok, context |> Map.put(:workspace_view, workspace_view) |> Map.put(:html, html)}
      end

      then_ "it does not ask them anything they have already said", context do
        refute context.html =~ ~r/sign[\s-]?in|log[\s-]?in/i,
               "the interview asked about sign-in again, which the shaping conversation " <>
                 "already settled in plain terms. Got: #{context.html}"

        refute context.html =~ ~r/separate (business|businesses|copy|copies)|own copy/i,
               "the interview asked about separate copies again, which the shaping " <>
                 "conversation already settled in plain terms. Got: #{context.html}"

        {:ok, context}
      end

      then_ "the agent answers with what they told intake already in hand", context do
        assert has_element?(context.workspace_view, "[data-test='interview-progress']"),
               "expected the interview to be under way with the shaping answers already " <>
                 "recorded on the plan, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
