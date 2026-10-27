defmodule CodeMySpecSpex.Story1166.Criterion2560Spex do
  @moduledoc "Story 1166, criterion 2560: promotion timing is linked from Advanced."

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "John can find promotion timing in the Advanced menu", criterion: 2560 do
    scenario "the project menu links to its promotion timing page" do
      given_ "John has an active project", context do
        # given: already true — `setup :setup_active_project` creates it.
        {:ok, context}
      end

      when_ "John opens a page with the project navigation", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-performance")

        {:ok, Map.put(context, :page, view)}
      end

      then_ "Advanced contains a link to this project's promotion timing", context do
        assert has_element?(context.page, "summary", "Advanced")

        assert has_element?(
                 context.page,
                 "details a[href='/app/projects/#{context.project.id}/promotion-timing']",
                 "Promotion timing"
               )

        {:ok, context}
      end
    end
  end
end
