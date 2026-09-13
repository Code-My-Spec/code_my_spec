defmodule CodeMySpecSpex.Story990.Criterion3400Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 3400 — Choosing cloud asks for payment before the shared host
  provisions anything.

  Rule: a working copy on the shared host is a real container on a real box,
  and provisioning one for every visitor who confirms "cloud" spends it on
  everyone who never pays.

  Today `IntakeLive.Workspace` calls `Workspaces.boot/1` unconditionally the
  moment a signed-up visitor with `location: :cloud` reaches `/build/workspace`
  — this criterion is the gate that has to sit in front of that call. Modelled
  as the same page's `:local` variant already is: a distinct state
  (`data-test="cloud-payment"`) rather than a separate route, since the
  visitor is still in the one conversation the rest of this story insists on.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)
    :ok
  end

  spex "Payment comes before a working copy is provisioned on the shared host" do
    scenario "Choosing cloud asks for payment before the shared host provisions anything" do
      given_ "a visitor who has signed up and reaches the local-or-cloud choice", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "they choose cloud", context do
        to = confirm_plan(context.view, %{location: "cloud"})

        assert to == "/build/workspace",
               "expected a signed-in visitor choosing cloud to be sent to their workspace, " <>
                 "got #{inspect(to)}"

        {:ok, live, html} = live(context.conn, to)

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "they are asked to pay before a working copy is provisioned on the shared host",
            context do
        assert has_element?(context.live, "[data-test='cloud-payment']") or
                 context.html =~ ~r/\bpay\b|payment|card details/i,
               "expected to be asked to pay before anything was provisioned, got: " <>
                 "#{context.html}"

        {:ok, context}
      end

      then_ "nothing is provisioned on the shared host until payment succeeds", context do
        # "Open your application" only ever renders once the workspace is
        # actually running — unlike a bare "running", which the payment
        # card's own copy ("Running in the cloud is $100/month") would
        # false-positive on.
        refute context.html =~ "Open your application",
               "a working copy started coming up before payment was ever asked for — " <>
                 "provisioning on the shared host must wait for it. Got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
