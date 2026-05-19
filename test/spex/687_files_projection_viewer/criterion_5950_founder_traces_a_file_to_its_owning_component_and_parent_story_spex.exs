defmodule CodeMySpecSpex.Story687.Criterion5950Spex do
  @moduledoc """
  Story 687 — Files Projection Viewer
  Criterion 5950 — From the files page, the founder can click through
  a file's component link to land on the component's detail page; from
  the component, the parent story is reachable.

  This story owns the files-page → component-page jump. The
  component-page → story-page jump is the existing component view's
  contract, so this scenario only asserts that the component link on a
  file row navigates to a real component page where the linked story
  appears.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Founder traces a file to its owning component and parent story" do
    scenario "clicking the file's component link lands on the component page where the story appears" do
      given_ :synced_context_component
      given_ :story_linked_to_component

      when_ "the founder opens the files page and clicks the spec file's component link",
            context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        row_selector =
          "[data-test='file-row'][data-file-path*='example_context.spec.md']"

        component_path =
          files_live
          |> element("#{row_selector} [data-test='file-component-link']")
          |> render()
          |> extract_href!()

        {:ok, component_live, component_html} = live(context.conn, component_path)

        {:ok,
         Map.merge(context, %{
           component_path: component_path,
           component_live: component_live,
           component_html: component_html
         })}
      end

      then_ "the component page renders for the owning component", context do
        assert context.component_path =~ "/components/#{context.component.id}",
               "expected the component link to point at /components/#{context.component.id}, got #{context.component_path}"

        # Anchor: the component's module name should appear on its own page.
        assert context.component_html =~ context.component.module_name,
               "expected the component page to render the component's module name (#{context.component.module_name})"

        {:ok, context}
      end

      then_ "the linked story is reachable from the component page", context do
        assert context.component_html =~ context.story.title,
               "expected the component page to surface the linked story's title (#{context.story.title})"

        {:ok, context}
      end
    end
  end

  defp extract_href!(rendered_html),
    do: href_match(Regex.run(~r/href=["']([^"']+)["']/, rendered_html), rendered_html)

  defp href_match([_, href], _html), do: href
  defp href_match(_, html), do: raise("could not extract href from rendered component link: #{inspect(html)}")
end
