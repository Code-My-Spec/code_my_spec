defmodule CodeMySpecSpex.Story963.Criterion2909Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2909 — Progress reads as sentences, not as a build log.

  Rule: The main agent describes the project in language that assumes no code.

  The translating job, which is the reason this agent exists rather than
  pointing a non-technical user at the working copies page.

  ## What a spex can assert here, and what it cannot

  This criterion is about what the agent *says*. A spex drives surfaces, not a
  model, so it cannot assert prose — and a check dressed up to look as though
  it does would go green while the thing the criterion cares about was wrong.

  So this asserts that the project offers a plain-language account at all, and that what it renders is not a build log. Whether the sentences are good ones is left to QA, where a person reads
  what the agent actually said.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent describes the project in language that assumes no code" do
    scenario "Progress reads as sentences, not as a build log" do
      given_ "work is happening on one of my working copies", context do
        copy = CodeMySpec.TempFile.dir("spex_2909")
        File.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{joined.working_copy_id}"
          )

        live |> element("[data-test=designate-main-copy]") |> render_click()

        {:ok, Map.put(context, :copy, copy)}
      end

      when_ "I ask the main agent how the project is going", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "I get a short plain-language account of where the project is", context do
        assert context.html =~ "data-test=\"project-summary\"",
               "there is nowhere on the page for a plain-language account of the " <>
                 "project, so the only thing a non-technical user can read is the raw " <>
                 "transcript of an agent working"

        {:ok, context}
      end

      then_ "and it names no file paths, module names or commands", context do
        summary = summary_text(context.html)

        refute summary =~ ~r{lib/|test/|\.exs?\b|mix },
               "the summary reads as a build log. Paths, module names and commands are " <>
                 "the vocabulary this agent exists to translate out of. Got: " <>
                 String.slice(summary, 0, 200)

        {:ok, context}
      end
    end
  end

  defp summary_text(html) do
    case Regex.run(~r/data-test="project-summary"[^>]*>(.*?)</s, html) do
      [_, text] -> text
      nil -> ""
    end
  end
end
