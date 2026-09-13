defmodule CodeMySpecSpex.Story990.Criterion3403Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 3403 — Asked about something else, it comes back to the plan.

  Rule: an answer that is not about the application does not move the
  conversation forward — the shaper does not follow it, and asks again.

  This is the one rule in `Intake.Shaper.Llm`'s own prompt that has no
  deterministic counterpart: `Shaper.Scripted` (what every other spex in this
  story runs against) always concludes from whatever text it is given, so it
  cannot exhibit — or fail to exhibit — a redirect. The claim is entirely the
  model's judgment, so proving it means a real call, recorded once and
  replayed like `CodeMySpec.Intake.ShaperLlmAlloyTest`'s two calls already are.

  ## Recording

  `@mode` below is `:replay`. To re-record against a live model:

      1. Flip `@mode` to `:record`.
      2. `rm test/cassettes/intake/shaper_redirects_off_topic.json`
      3. `MIX_ENV=test elixir -S mix spex --pattern \
         "test/spex/990_*/criterion_3403*"`
      4. Read what the model actually asked the second time and update the
         `then_` assertions below to match its real wording rather than a
         guess.
      5. Flip `@mode` back to `:replay` and re-run to confirm replay is clean.
      6. Commit the cassette alongside this file.

  Swaps `:shaper` to the real `CodeMySpec.Intake.Shaper.Llm` for this file
  only (`config/test.exs` runs every other spex in this story against
  `Shaper.Scripted`) and restores it on exit.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  @mode :replay
  @cassette_dir "test/cassettes/intake"
  @cassette_name "shaper_redirects_off_topic"
  @model "anthropic:claude-sonnet-5"

  # Genuinely open — nothing here tells the model whether people log in or
  # whether this is one business's tool or many, so the first question is a
  # real one worth asking, and there is somewhere for a redirect to return to.
  @description "I want a tool to help me keep track of things for my business"
  @off_topic "What's the capital of France?"

  setup do
    previous_intake = Application.get_env(:code_my_spec, CodeMySpec.Intake, [])
    previous_key = Application.get_env(:req_llm, :anthropic_api_key)

    cassette_path = Path.join(@cassette_dir, @cassette_name <> ".json")
    session_id = ReqCassette.Session.start_session(cassette_path, nil)

    plug =
      {ReqCassette.Plug,
       %{
         cassette_name: @cassette_name,
         cassette_dir: @cassette_dir,
         mode: @mode,
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
      # Left deterministic on purpose: a real Anthropic key configured for the
      # shaper makes `Planner.impl/0` pick `Planner.Llm` too unless told
      # otherwise, and this scenario has no business paying for or depending
      # on a real plan — only the shaper's redirect is under test.
      planner: CodeMySpec.Intake.Planner.Inferred,
      model: @model,
      req_options: [plug: plug]
    )

    Application.put_env(:req_llm, :anthropic_api_key, anthropic_key(@mode))

    on_exit(fn ->
      ReqCassette.Session.end_session(cassette_path, session_id)
      Application.put_env(:code_my_spec, CodeMySpec.Intake, previous_intake)
      restore_anthropic_key(previous_key)
    end)

    :ok
  end

  defp restore_anthropic_key(nil), do: Application.delete_env(:req_llm, :anthropic_api_key)
  defp restore_anthropic_key(value), do: Application.put_env(:req_llm, :anthropic_api_key, value)

  # A placeholder is correct in replay — the recorded interaction is matched
  # by method and uri, never by the Authorization header, and the real key is
  # stripped by `filter_request_headers` before anything reaches disk anyway.
  defp anthropic_key(:replay), do: "replayed-key"

  defp anthropic_key(:record) do
    System.get_env("ANTHROPIC_API_KEY") || key_from_env_file() ||
      flunk("no Anthropic key. Set ANTHROPIC_API_KEY, or put one in envs/dev.env.")
  end

  defp key_from_env_file do
    with {:ok, contents} <- File.read("envs/dev.env") do
      contents
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case String.split(line, "=", parts: 2) do
          ["ANTHROPIC_API_KEY", value] ->
            case value |> String.trim() |> String.trim("\"") do
              "" -> nil
              key -> key
            end

          _ ->
            nil
        end
      end)
    else
      _ -> nil
    end
  end

  spex "An answer that is not about the application does not move the plan forward" do
    scenario "Asked about something else, it comes back to the plan" do
      given_ "a visitor part way through intake, having just been asked a question",
            context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, @description)
        html = render(view)

        assert has_element?(view, "form[phx-submit=answer]"),
               "expected the real shaper to have a genuine question to ask about this " <>
                 "deliberately open description, got: #{html}"

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      when_ "they ask it something that has nothing to do with what they are building",
            context do
        html =
          context.view
          |> form("form[phx-submit=answer]", %{answer: @off_topic})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it does not answer the question", context do
        refute context.html =~ "Paris",
               "the model answered the off-topic question instead of declining to follow " <>
                 "it, got: #{context.html}"

        {:ok, context}
      end

      then_ "it asks them the next thing it needs to finish the plan", context do
        assert has_element?(context.view, "form[phx-submit=answer]"),
               "expected the conversation to still be asking toward the plan rather than " <>
                 "having concluded from an answer that said nothing about the business, " <>
                 "got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
