defmodule CodeMySpecSpex.Story812.Criterion6515Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6515 — Rule 5: Custom dimensions `harness` + `location`
  are queryable for install events.

  The actual GA-admin registration of these custom dimensions is
  operator state (Admin → Custom Definitions → Custom Dimensions
  in the GA console). What we CAN assert in code: every
  install_command_copy dispatch site sets `harness` + `location`,
  so once the GA admin registration lands, the slice queries find
  data.

  Codebase-grep + dispatch-call pattern: scans the four install-card
  callsites for `data-event-name="install_command_copy"` and the
  matching `data-event-location` + `data-event-harness` attributes.

  Driving spec — fails if any install-card callsite drops a param.
  GA admin state itself is operator-validated via the daily
  analytics snapshot.
  """

  use CodeMySpecSpex.Case

  @callsite_paths [
    "lib/code_my_spec_web/components/marketing_components.ex",
    "lib/code_my_spec_web/controllers/page_html/home.html.heex",
    "lib/code_my_spec_web/controllers/page_html/code_my_spec.html.heex"
  ]

  spex "install_command_copy callsites carry harness + location attributes" do
    scenario "every data-event-name=install_command_copy site sets both data-event-* params" do
      given_ "the four install-card placements", context do
        {:ok, context}
      end

      when_ "we scan the templates for install_command_copy callsites", context do
        sites =
          Enum.flat_map(@callsite_paths, fn path ->
            case File.read(path) do
              {:ok, content} -> [{path, content}]
              _ -> []
            end
          end)

        {:ok, Map.put(context, :sites, sites)}
      end

      then_ "every install_command_copy block carries data-event-location and data-event-harness",
            context do
        assert context.sites != [], "expected install-card callsites to exist"

        offenders =
          Enum.flat_map(context.sites, fn {path, content} ->
            blocks = Regex.scan(~r/data-event-name="install_command_copy"[^>]*/, content)

            Enum.flat_map(blocks, fn [block] ->
              missing =
                [
                  {"data-event-location", "location"},
                  {"data-event-harness", "harness"}
                ]
                |> Enum.reject(fn {attr, _} -> String.contains?(block, attr) end)

              if missing == [] do
                []
              else
                [{path, block, Enum.map(missing, &elem(&1, 1))}]
              end
            end)
          end)

        assert offenders == [], format_offenders(offenders)

        {:ok, context}
      end
    end
  end

  defp format_offenders(offenders) do
    """
    install_command_copy callsites missing required data-event-* attributes:

    #{Enum.map_join(offenders, "\n\n", fn {path, block, missing} -> "  #{path}\n    block: #{block}\n    missing: #{inspect(missing)}" end)}
    """
  end
end
