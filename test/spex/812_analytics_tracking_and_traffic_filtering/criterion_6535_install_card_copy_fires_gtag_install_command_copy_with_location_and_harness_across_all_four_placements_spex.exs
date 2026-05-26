defmodule CodeMySpecSpex.Story812.Criterion6535Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6535 — Rule 4 (hybrid): Install-card copy fires
  `gtag('event', 'install_command_copy', ...)` with `location` and
  `harness` across all four placements.

  Hybrid design: install_command_copy is a browser behavior event fired
  by gtag, not forwarded to the server via the analytics API. The
  copy-button handler in app.js must call `gtag('event', ...)` directly
  rather than POSTing to `/api/browser/analytics/event`.

  Two assertions:
  1. `app.js` fireCopyEvent calls `gtag('event', name, ...)` using the
     data-event-name variable — not a hardcoded event name and not a fetch
     to `/api/browser/analytics/event`.
  2. The four install-card callsites in templates still carry
     `data-event-location` and `data-event-harness` so the JS handler
     can forward both params to gtag.

  Codebase-grep pattern — identical in spirit to criterion_6515.
  Fails if the JS copy handler still POSTs to the server or if any
  install-card template drops a required data-event-* attribute.
  """

  use CodeMySpecSpex.Case

  @app_js_path "assets/js/app.js"

  @callsite_paths [
    "lib/code_my_spec_web/components/marketing_components.ex",
    "lib/code_my_spec_web/controllers/page_html/home.html.heex",
    "lib/code_my_spec_web/controllers/page_html/code_my_spec.html.heex"
  ]

  spex "Install-card copy fires gtag install_command_copy with location + harness" do
    scenario "app.js calls gtag for install_command_copy instead of the analytics API" do
      given_ "the app.js copy-button handler", context do
        content = File.read!(@app_js_path)
        {:ok, Map.put(context, :app_js, content)}
      end

      when_ "we inspect the fireCopyEvent function", context do
        {:ok, context}
      end

      then_ "fireCopyEvent delegates to gtag using the data-event-name variable", context do
        # The correct implementation reads the event name from the button's
        # data-event-name attribute (variable `name`) and passes it to gtag,
        # rather than hardcoding 'install_command_copy'. This lets any
        # data-event-name value route through the same handler.
        assert context.app_js =~ ~r/gtag\(\s*['"]event['"]\s*,\s*name\s*,/,
               """
               expected app.js fireCopyEvent to call gtag('event', name, ...) using the
               data-event-name variable — found no matching call.

               The implementation should read the event name from the button attribute
               and pass it as the variable `name`, not as a hardcoded string.
               """

        {:ok, context}
      end

      then_ "app.js does not POST install_command_copy to the server analytics API", context do
        # The old pattern POSTed to /api/browser/analytics/event.
        # In the hybrid design, install_command_copy is a gtag event only.
        # The API endpoint may still exist for other events, but the
        # fireCopyEvent path must not use it.
        refute context.app_js =~ ~r/api\/browser\/analytics\/event[^)]*install_command_copy/,
               "expected app.js fireCopyEvent to call gtag, not POST to the server analytics API"

        {:ok, context}
      end
    end

    scenario "every install-card callsite still carries data-event-location and data-event-harness" do
      given_ "the four install-card placement templates", context do
        sites =
          Enum.flat_map(@callsite_paths, fn path ->
            case File.read(path) do
              {:ok, content} -> [{path, content}]
              _ -> []
            end
          end)

        {:ok, Map.put(context, :sites, sites)}
      end

      when_ "we scan the templates for install_command_copy callsites", context do
        {:ok, context}
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
                |> Enum.reject(fn {attr, _label} -> String.contains?(block, attr) end)

              if missing == [] do
                []
              else
                [{path, block, Enum.map(missing, &elem(&1, 1))}]
              end
            end)
          end)

        assert offenders == [],
               format_offenders(offenders)

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
