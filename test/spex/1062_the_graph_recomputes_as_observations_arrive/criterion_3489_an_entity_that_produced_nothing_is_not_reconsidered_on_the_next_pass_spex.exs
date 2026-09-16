defmodule CodeMySpecSpex.Story1062.Criterion3489Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3489 — An entity that produced nothing is not reconsidered on the
  next pass.

  Rule: the graph can tell an entity it computed and found empty from one it
  has never computed.

  ## The two look identical from the rows

  `stale_entities/3` asks the rows which entities it has already computed, and
  an entity that produced no rows cannot be in that answer. So it is counted as
  never-computed — `appeared` — recomputed, found empty again, and counted as
  never-computed on the next pass, and on every pass after that.

  Eighteen entities on this project were in that state: eleven infrastructure,
  whose template is `[]` by design, and seven live contexts under a config that
  removes every artifact their template asks for. The `appeared=19` that
  `why_all/5` prints is them, and that function's own comment says a population
  which never shrinks is "a guard that can never pass".

  ## Why it is worth a criterion rather than a note

  The cost is small and the diagnostic is not. `/dev/graph` shows the stale set
  with one instruction beside it: if it does not empty after the next pass,
  something wrote without announcing it — trace these back to a writer. It
  never empties, and there is no writer. Nothing wrote because there was
  nothing to write.

  That is the same failure as a silent writer with the sign reversed, and it
  costs the same thing: somebody's afternoon, looking for a cause that is not
  there. Criterion 3490 is the other half — the case where producing nothing is
  a fault rather than a design, and has to say so.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphReadHelpers

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A pass settles what it computed, including what it computed to nothing" do
    scenario "a component whose type has no requirements at all" do
      given_ :context_with_infrastructure_sibling

      when_ "a pass runs and the engineer looks at what is still stale", context do
        _settled = GraphReadHelpers.read_settled_graph(context)

        {:ok, live, _html} = live(context.conn, "/dev/graph")

        html =
          live
          |> element("form[phx-change='select']")
          |> render_change(%{"project" => context.project.id})

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the whole project is not declared stale on its account", context do
        refute context.html =~ "Every entity reads stale",
               """
               One component that can never hold a row makes every pass a full
               recompute.

               `verdict/5` calls it "everything is stale" when the stale set is
               as large as the recorded one, and the recorded set is derived
               from the rows. A component with no rows is never recorded and
               always stale, so on a project with two components and one of them
               infrastructure the comparison is 1 >= 1 on every pass, for good.

               That is the arithmetic on a fixture. On a real project it is
               eighteen permanent entries against a few thousand, which does not
               tip the verdict and costs a recompute each instead — quieter, and
               the reason it went unnoticed.
               """

        {:ok, context}
      end

      # The page's own words, minus the apostrophe — it renders escaped, and the
      # first version of this needle matched nothing while the page was saying
      # exactly what was wanted.
      then_ "and the entities it did compute are settled", context do
        assert context.html =~ "agree with the rows being served",
               """
               The pass left entities stale that it should have settled.

               This is the list `/dev/graph` tells you to trace back to a writer
               that skipped its announcement. Anything permanently in it makes
               that instruction wrong, and makes the entries that *are* a silent
               writer unreadable among them.
               """

        {:ok, context}
      end
    end
  end
end
