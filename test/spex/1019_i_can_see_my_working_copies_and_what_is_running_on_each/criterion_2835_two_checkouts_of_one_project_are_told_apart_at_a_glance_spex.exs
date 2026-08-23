defmodule CodeMySpecSpex.Story1019.Criterion2835Spex do
  @moduledoc """
  Story 1019 — I can see my working copies and what is running on each.
  Criterion 2835 — Two checkouts of one project are told apart at a glance.

  Rule: A working copy is identifiable without reading a path.

  `Harnesses.issue/3` already takes a label and nothing sets one, so today every
  copy would render as its root. Two checkouts of one project differ in one
  directory somewhere deep in a path, and on this machine one of them lives under
  `/var/folders/3j/35g_3wbj1dd_mhn49jxvdlcw0000gn/T/`. That is not a distinction
  anybody reads correctly at speed.

  It is also not cosmetic. During story 1018's QA three agents ran at once and
  their rows were mutually indistinguishable, which is the condition under which
  somebody stops the wrong one. This rule is why stopping is deliberately not on
  this page yet, and it is what would have to be true first.

  The second assertion is the one that makes the rule worth having: a name
  nobody can set is a name nobody has. The join already accepts one; the page has
  to let a person change it, because the useful name is "the QA checkout" and
  only a person knows that.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A copy is known by a name, not a path" do
    scenario "Two checkouts of one project are told apart at a glance" do
      given_ "two working copies of the same project", context do
        join_working_copy(context, "/tmp/spex-1019-main", "main checkout")
        join_working_copy(context, "/tmp/spex-1019-qa", "the QA checkout")

        {:ok, context}
      end

      when_ "an engineer looks at the list", context do
        {:ok, live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "each carries a name they can recognise", context do
        assert context.html =~ "the QA checkout",
               "the copy's label is not rendered, so the only thing distinguishing " <>
                 "two rows is a path differing in one directory. Got: #{context.html}"

        assert context.html =~ "main checkout",
               "both copies need a name, not just the one that happens to be first"

        {:ok, context}
      end

      then_ "and naming one does not require editing a file on disk", context do
        assert has_element?(
                 context.live,
                 "[data-test='working-copy'][data-root='/tmp/spex-1019-qa'] [data-test='rename']"
               ),
               "there is no way to name a copy from here. `issue/3` has always " <>
                 "accepted a label and nothing sets one — a name nobody can set is " <>
                 "a name nobody has, and the useful name is 'the QA checkout', " <>
                 "which only a person knows."

        {:ok, context}
      end
    end
  end
end
