defmodule CodeMySpecSpex.Story1033.Criterion3420Spex do
  @moduledoc """
  Story 1033 — The handoff from onboarding to sales to building never breaks
  the conversation or the panel beside it.
  Criterion 3420 — The cloud choice reads as a purchase, not a config screen.

  Rule: phase two of this story's three-phase arc is named "sales" on
  purpose — per John, "This is literally the sales conversation, named as
  such rather than dressed up as a technical step." What the visitor sees
  when they choose cloud has to read like buying something, not like
  configuring infrastructure.

  Distinct from 990/3400 (whether payment is required before anything is
  provisioned — a sequencing claim) and from 990/3401 (that local skips
  payment). This criterion is about voice: plain purchase language, no
  provisioning vocabulary, wherever the payment step ends up living.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)
    :ok
  end

  spex "Choosing cloud reads as buying something, not configuring something" do
    scenario "The cloud choice reads as a purchase, not a config screen" do
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

      then_ "what they see asks for payment in plain terms", context do
        assert context.html =~ ~r/\bpay\b|payment|\$\d|card details/i,
               "expected plain purchase language when the visitor chose cloud, got: " <>
                 "#{context.html}"

        {:ok, context}
      end

      then_ "nothing frames it as a technical setting to configure", context do
        refute context.html =~ ~r/configur|provisioning options|infrastructure settings/i,
               "the cloud choice reads as a technical configuration step rather than a " <>
                 "purchase, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
