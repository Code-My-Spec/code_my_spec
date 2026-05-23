defmodule CodeMySpecSpex.Story812.Criterion6516Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6516 — Rule 5: Key activation events surface as
  conversions in GA4 reports.

  GA-admin "key event" registration is operator state (GA console
  Admin → Events). What we CAN assert in code: the canonical
  conversion-event names (`:sign_up`, `:install_command_copy`,
  `:first_cli_connect`) are still actually dispatched somewhere in
  `lib/`. If a refactor drops a dispatch, this spex flags it so the
  GA admin conversion remains aligned with reality.

  Codebase-grep pattern. GA console state itself is operator-validated
  via the daily snapshot.
  """

  use CodeMySpecSpex.Case

  @conversion_events [
    {"sign_up", ~r/Analytics\.dispatch\(\s*:sign_up/},
    # install_command_copy fires via /api/browser/analytics/event — the
    # event name lives in the data-event-name attribute, not a literal
    # Analytics.dispatch call.
    {"install_command_copy", ~r/data-event-name="install_command_copy"/},
    {"first_cli_connect", ~r/Analytics\.dispatch\(\s*:first_cli_connect/}
  ]

  @scan_paths ["lib"]

  spex "Key conversion events are still dispatched from app code" do
    scenario "every conversion event name appears as a dispatch site in lib/" do
      given_ "the canonical conversion-event set", context do
        {:ok, context}
      end

      when_ "we scan lib/ for each conversion event's dispatch site", context do
        files =
          @scan_paths
          |> Enum.flat_map(&list_files/1)
          |> Enum.filter(&File.regular?/1)
          |> Enum.map(fn path -> {path, File.read!(path)} end)

        missing =
          Enum.reject(@conversion_events, fn {_name, pattern} ->
            Enum.any?(files, fn {_path, content} -> Regex.match?(pattern, content) end)
          end)
          |> Enum.map(fn {name, _pattern} -> name end)

        {:ok, Map.put(context, :missing, missing)}
      end

      then_ "every conversion event name appears as a dispatch site", context do
        assert context.missing == [],
               """
               Conversion events have no dispatch site in lib/:

                 #{Enum.join(context.missing, ", ")}

               If you removed a dispatch, also remove the GA console "key event"
               registration for it — otherwise the conversions report counts
               will silently flatline.
               """

        {:ok, context}
      end
    end
  end

  defp list_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)

          cond do
            File.dir?(full) -> list_files(full)
            File.regular?(full) -> [full]
            true -> []
          end
        end)

      _ ->
        []
    end
  end
end
