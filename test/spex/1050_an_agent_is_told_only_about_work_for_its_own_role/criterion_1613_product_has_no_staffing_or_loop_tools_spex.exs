defmodule CodeMySpecSpex.Story1050.Criterion1613Spex do
  @moduledoc """
  Story 1050 — An agent is told only about work for its own role.
  Criterion 1613 — Product has no staffing or loop tools.

  John, a31f1cd6 step 4c: staffing is main's. Product designs on the main copy;
  it does not make or discard working copies, or switch their loops. Scoped
  through the harness, as story 1038's criterion 3020 requires: refused from
  inside a script, and refused by name.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentToolsHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @staffing ~w(create_working_copy offboard_working_copy set_working_copy_loop)

  spex "Product has no staffing or loop tools", criterion: 1613 do
    scenario "Product reaches for each staffing tool from a script and is refused" do
      given_ "a product agent", context do
        id = running_agent(context, %{"role" => "product"})
        {:ok, Map.put(context, :agent_id, id)}
      end

      when_ "its script calls each staffing and loop tool", context do
        replies =
          for tool <- @staffing do
            {tool, Fixtures.run_script("return #{tool}({})", agent_context(context))}
          end

        {:ok, Map.put(context, :replies, replies)}
      end

      then_ "each is refused, naming the tool and that product does not carry it", context do
        for {tool, reply} <- context.replies do
          said = reply |> elem(1) |> to_string()

          assert said =~ tool and said =~ ~r/product/i,
                 "product reached #{tool}, or was refused without being told why. " <>
                   "Got: #{inspect(said)}"
        end

        {:ok, context}
      end
    end
  end
end
