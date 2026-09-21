defmodule CodeMySpecSpex.Story990.Criterion3401Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 3401 — Choosing local starts a trial rather than a charge.

  Rule, as decided later than this criterion's original name: local is not
  free. It is its own $25/month tier — a visitor developing on their own
  machine needs a different pricing tier than one who never touches infra at
  all — with a 7-day trial so nothing is charged before the visitor has had
  a chance to use it. "Never asks for payment" stopped being true the moment
  that decision was made; what still has to hold is that nothing is *charged*
  today, and nothing on our infrastructure is provisioned either way, since
  `local` still never reaches `Workspaces.boot/1`
  (`IntakeLive.Workspace.mount_workspace/3` still branches to `assign_local/1`
  once the trial's card is confirmed).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  # `secret_key`/the price ids/`webhook_secret` are already set once, globally,
  # in config/test.exs — "every spex reads the same fixture values" is that
  # file's own reasoning for keeping them static rather than put_env'd and
  # on_exit-deleted per test, and this spex follows it: only the Req plug's
  # response is test-specific, and `Req.Test.stub/2` is already scoped to this
  # test's own process, not global VM state.
  setup do
    Req.Test.stub(CodeMySpec.Billing.StripeClient, &stripe_response/1)
    :ok
  end

  defp stripe_response(%{request_path: "/v1/customers"} = conn) do
    Plug.Conn.put_resp_content_type(conn, "application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "cus_criterion_3401"}))
  end

  defp stripe_response(%{request_path: "/v1/subscriptions"} = conn) do
    body = %{
      "id" => "sub_criterion_3401",
      "status" => "trialing",
      "latest_invoice" => nil,
      "pending_setup_intent" => %{"client_secret" => "seti_1_secret"}
    }

    Plug.Conn.put_resp_content_type(conn, "application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  spex "A visitor running their own copy gets a 7-day free trial, not a charge" do
    scenario "Choosing local starts a trial rather than a charge" do
      given_ "a visitor who has signed up and reaches the local-or-cloud choice", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "they choose local", context do
        to = confirm_plan(context.view, %{location: "local"})

        assert to == "/build/workspace",
               "expected a signed-in visitor choosing local to be sent to their workspace, " <>
                 "got #{inspect(to)}"

        {:ok, live, html} = live(context.conn, to)

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "they are asked to start a 7-day trial, not shown the walkthrough yet", context do
        refute has_element?(context.live, "[data-test='local-instructions']"),
               "expected the trial's card to come before the install walkthrough, got: " <>
                 "#{context.html}"

        assert context.html =~ "7 days free",
               "expected the trial to be offered before any charge, got: #{context.html}"

        {:ok, context}
      end

      then_ "they are not charged — nothing is due until the trial ends", context do
        assert context.html =~ "7 days free, then $25/month",
               "expected local's own trial framing, not an immediate charge, got: " <>
                 "#{context.html}"

        refute context.html =~ "Running in the cloud",
               "a visitor who chose local must not be shown the cloud tier's payment copy"

        {:ok, context}
      end

      when_ "they confirm the trial's card", context do
        html = render_hook(context.live, "payment_confirmed", %{})

        {:ok, Map.put(context, :html, html)}
      end

      then_ "they move straight into the agent-guided install walkthrough", context do
        assert has_element?(context.live, "[data-test='local-instructions']"),
               "expected the local install walkthrough once the trial started, got: " <>
                 "#{context.html}"

        {:ok, context}
      end

      then_ "nothing is provisioned on our infrastructure either way", context do
        refute context.html =~ "Open your application",
               "local never boots a container on the shared host, trial or not — got: " <>
                 "#{context.html}"

        {:ok, context}
      end
    end
  end
end
