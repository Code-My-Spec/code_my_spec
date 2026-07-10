defmodule CodeMySpecSpex.MarketingCopy.RetiredPhrasesSpex do
  @moduledoc """
  Marketing copy contract: no codemyspec.com surface may render any phrase
  from `marketing/06_messaging.md` "Phrases to retire, permanently."

  ## Why this exists

  The 9-day signup drought (2026-05-10 → 2026-05-19) was caused in part by
  4/27 platform-as-wedge marketing copy continuing to ship on rendered
  surfaces after the 2026-05-07 strategy revert. The marketing-strategy
  doc was reverted; the codebase wasn't. Reddit traffic from r/ClaudeAI
  and r/elixir landed on a register page whose hero said "Run your business
  — marketing, engineering, ops — from one terminal" — a phrase the
  marketing doc had explicitly retired three days earlier.

  This spec is the durable infrastructure called out in the diagnostic
  (Stories B and D of `signup-funnel-leak-and-release-crash.md`). It walks
  every public marketing surface through the same engagement path a real
  visitor would — LiveView mount, controller render — and asserts the
  rendered HTML against the canonical retired-phrase list.

  ## Source of truth

  `marketing/06_messaging.md` section "Phrases to retire, permanently"
  (codemyspec_marketing repo). The list below is mirrored here so the
  spec has no cross-repo dependency. Sync the list when the marketing
  doc adds or removes a retired phrase. The `marketing-repo` strategy
  doc remains arbiter on what counts as retired.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecWeb.Layouts

  # Mirrored from `marketing/06_messaging.md` "Phrases to retire,
  # permanently" plus close paraphrases the 5/19 audit caught actually
  # shipping (e.g. "Run your entire software business" was the homepage
  # disguise of "Run your business — ... — from one terminal").
  @retired_phrases [
    "Lights out software factory",
    "10x your velocity",
    "Replace your developers",
    "Any 8-year-old can build a Harry Potter game",
    "Next-gen AI-powered development",
    "Revolutionize your workflow",
    "AI marketing automation",
    "Mentioning my stack is a total disqualifier",
    "Run your business — marketing, engineering, ops — from one terminal",
    "Platform of harnesses for the founder doing every job",
    "Run your entire software business",
    "founder doing every job",
    "Built for the founder doing every job",
    "platform of harnesses for the technical founder",
    "platform of harnesses for the founder"
  ]

  spex "Marketing surfaces contain no retired phrase from marketing/06_messaging.md" do
    scenario "The homepage renders no retired phrase" do
      given_ "the public homepage", context do
        {:ok, Map.put(context, :path, "/")}
      end

      when_ "a visitor fetches the page", context do
        conn = get(context.conn, context.path)
        {:ok, Map.put(context, :body, html_response(conn, 200))}
      end

      then_ "no retired marketing phrase appears in the rendered HTML", context do
        assert_no_retired_phrases(context.body, context.path)
        {:ok, context}
      end
    end

    scenario "The /users/register LiveView renders no retired phrase" do
      given_ "the public registration LiveView path", context do
        {:ok, Map.put(context, :path, "/users/register")}
      end

      when_ "a visitor mounts the LiveView", context do
        {:ok, _lv, html} = live(context.conn, context.path)
        {:ok, Map.put(context, :body, html)}
      end

      then_ "no retired marketing phrase appears in the rendered HTML", context do
        assert_no_retired_phrases(context.body, context.path)
        {:ok, context}
      end
    end

    scenario "The /users/log-in LiveView renders no retired phrase" do
      given_ "the public log-in LiveView path", context do
        {:ok, Map.put(context, :path, "/users/log-in")}
      end

      when_ "a visitor mounts the LiveView", context do
        {:ok, _lv, html} = live(context.conn, context.path)
        {:ok, Map.put(context, :body, html)}
      end

      then_ "no retired marketing phrase appears in the rendered HTML", context do
        assert_no_retired_phrases(context.body, context.path)
        {:ok, context}
      end
    end

    # /products/code-my-spec 301s to /developers since the 2026-07
    # install-page restructure — lint the pages that actually render.
    scenario "The /developers dead view renders no retired phrase" do
      given_ "the public developers page", context do
        {:ok, Map.put(context, :path, "/developers")}
      end

      when_ "a visitor fetches the page", context do
        conn = get(context.conn, context.path)
        {:ok, Map.put(context, :body, html_response(conn, 200))}
      end

      then_ "no retired marketing phrase appears in the rendered HTML", context do
        assert_no_retired_phrases(context.body, context.path)
        {:ok, context}
      end
    end

    scenario "The /install page renders no retired phrase" do
      given_ "the public install page", context do
        {:ok, Map.put(context, :path, "/install")}
      end

      when_ "a visitor fetches the page", context do
        conn = get(context.conn, context.path)
        {:ok, Map.put(context, :body, html_response(conn, 200))}
      end

      then_ "no retired marketing phrase appears in the rendered HTML", context do
        assert_no_retired_phrases(context.body, context.path)
        {:ok, context}
      end
    end

    scenario "The shared blog-post install signature renders no retired phrase" do
      given_ "the end-of-post install signature component", context do
        {:ok, Map.put(context, :path, "Layouts.install_signature/1")}
      end

      when_ "the component is rendered as it appears on every blog post",
            context do
        html = render_component(&Layouts.install_signature/1, %{})
        {:ok, Map.put(context, :body, html)}
      end

      then_ "no retired marketing phrase appears in the rendered HTML", context do
        assert_no_retired_phrases(context.body, context.path)
        {:ok, context}
      end
    end
  end

  defp assert_no_retired_phrases(body, path) do
    for phrase <- @retired_phrases do
      refute body =~ phrase, """
      Retired marketing phrase found on #{path}: #{inspect(phrase)}

      Source of truth: `marketing/06_messaging.md` section "Phrases to
      retire, permanently" (codemyspec_marketing repo). Replace with
      on-strategy copy from the engineer-founder lens (Lens A) or the
      Phoenix lens (Lens B) — see `marketing/05_positioning.md` section
      "Phrases to use".
      """
    end
  end
end
