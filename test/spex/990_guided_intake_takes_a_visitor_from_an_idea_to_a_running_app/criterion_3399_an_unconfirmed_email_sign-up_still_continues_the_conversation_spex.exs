defmodule CodeMySpecSpex.Story990.Criterion3399Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 3399 — An unconfirmed email sign-up still continues the
  conversation.

  Rule: email from the sign-up card is a soft gate — an identity, not a
  checkpoint.

  `UserLive.Registration` today sends a magic link and lands the visitor on
  `/users/check-email`, which cannot be what this criterion asks for: a
  visitor who has to leave the tab, open their inbox and click a link has not
  continued anything. The design this criterion states is that email from
  *this* card logs the visitor in immediately — the row exists, a session
  exists, `confirmed_at` is not set yet — and confirming later is a fact about
  the account rather than a condition on using it.

  ## What a spex can observe here

  Per 963/2905, a spex drives surfaces and does not read the database — so
  `confirmed_at` itself is not read directly in a `then_`. What is observed is
  its user-visible consequence: nothing about being unconfirmed is allowed to
  block the visitor, so the criterion is encoded as "the conversation
  continues, uninterrupted" rather than as a column value.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)
    :ok
  end

  spex "Email from the sign-up card is an identity, not a checkpoint" do
    scenario "An unconfirmed email sign-up still continues the conversation" do
      given_ "a visitor who has reached the sign-up card", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        # Local, deliberately — this criterion is about the sign-up card
        # itself, not the separate cloud payment gate (990/3400), and cloud
        # would put a payment step between sign-up and the workspace this
        # scenario is asserting reaches immediately.
        result =
          view
          |> form("form[phx-submit=confirm_names]", %{
            plan: %{account_name: "Acme", project_name: "Widget Tracker", location: "local"}
          })
          |> render_submit()

        unless is_binary(result) do
          flunk(
            "expected confirming the plan to show the sign-up card in the same " <>
              "conversation; the visitor was sent elsewhere instead: #{inspect(result)}"
          )
        end

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      # A plain form POST, not `render_submit` on the LiveView — the real
      # sign-up card submits to a controller (`IntakeSignupController`)
      # rather than a `phx-submit` event, because establishing the session
      # cookie is a controller's job; a LiveView process cannot write it.
      when_ "they sign up with email from the sign-up card", context do
        conn =
          post(context.conn, "/build/sign-up", %{
            "user" => %{"email" => "visitor-3399@example.com"}
          })

        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "they land in the cockpit continuing the same conversation immediately",
            context do
        to = redirected_to(context.conn)

        refute to == "/users/check-email",
               "expected the visitor to continue immediately rather than being sent to " <>
                 "wait for an email"

        assert to == "/build/workspace",
               "expected email sign-up to send the visitor straight into their workspace, " <>
                 "got #{inspect(to)}"

        {:ok, workspace_view, html} = live(context.conn, to)

        {:ok, context |> Map.put(:workspace_view, workspace_view) |> Map.put(:html, html)}
      end

      then_ "they are not shown a screen asking them to wait for an email", context do
        refute context.html =~ ~r/check your (inbox|email)/i,
               "expected no wait-for-email screen, got: #{context.html}"

        {:ok, context}
      end

      then_ "nothing about the account being unconfirmed stops them from continuing",
            context do
        assert has_element?(context.workspace_view, "form[phx-submit=answer]") or
                 has_element?(context.workspace_view, "[data-test='local-instructions']"),
               "expected the interview or the local walkthrough to be usable immediately, " <>
                 "not blocked on confirming the account, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
