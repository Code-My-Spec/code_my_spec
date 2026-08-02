defmodule CodeMySpec.ContentPublishing.Ctas do
  @moduledoc """
  Named inline CTA blocks, expanded from shortcodes at publish time.

  ## Why this module lives here and not in `CodeMySpecWeb`

  `ContentPublishing.render_body/3` needs to call these, and the `CodeMySpec`
  boundary declares `deps: [CodeMySpec.Environments, CodeMySpec.Repo]`, so it
  cannot reach the web layer. Defining them inside the `CodeMySpec` boundary lets
  both sides use them: the publish path directly, and `CodeMySpecWeb` via its
  existing `deps: [CodeMySpec]` with `exports: :all`. One definition, no
  duplication.

  ## Why shortcodes rather than raw HTML in markdown

  Hand-written HTML in post bodies was tried and it is a trap:

  * **Tailwind never scans markdown.** Utilities that are not already used
    somewhere under `lib/` or `assets/` are simply absent from the bundle, so
    `block`, `text-sm`, and `my-8` silently did nothing in a post body. Markup
    defined in this module is scanned, so every class it uses is guaranteed to
    compile.
  * **Prose styles override link colour**, which rendered a `btn-primary` as
    teal-on-teal (contrast 1.0, invisible). `not-prose` on the wrapper fixes it
    once here instead of once per post.
  * **Earmark drops a closing tag when block elements of the same name nest.**
    A `<div>` inside a `<div>` loses one `</div>` and swallows the rest of the
    page. This module keeps the outer element an `<aside>` for that reason.
  * 105 posts times any markup tweak is 105 edits. Here it is one.

  ## Usage in a content file

      {{nontechnical_founder_cta}}

      {{nontechnical_founder_cta headline="10% of scanned Lovable apps shipped with the database wide open." sub="CodeMySpec catches that before it ships." campaign="lovable-alternatives"}}

  Every attribute is optional; each CTA carries defaults so the bare form works.
  Unknown names are left in the body untouched and reported by `validate/1`, so a
  typo is visible rather than silently dropped.

  ## Naming

  Names are deliberately specific (`nontechnical_founder_cta`, not `cta`). There
  will be several, aimed at different readers, and a generic name would not say
  which one a post is using.
  """
  use Phoenix.Component

  @shortcode ~r/\{\{\s*([a-z0-9_]+)\s*((?:[a-z_]+="[^"]*"\s*)*)\}\}/

  @doc """
  Every registered CTA name.

  Two shapes, because two audiences. `:card` is bold with a button, for
  non-technical readers who need an obvious next step. `:aside` is an
  understated monospace note with an inline link, for engineers, who read a
  button in the middle of a technical post as an advertisement. Each name picks
  its shape in `defaults/1`.
  """
  def names,
    do: ~w(
      nontechnical_founder_cta
      owned_code_cta
      verification_gate_cta
      enforced_boundary_cta
      portable_spec_cta
      design_gate_cta
      build_speed_cta
      verified_before_ship_cta
      enforced_spec_cta
      harness_not_model_cta
      repo_native_memory_cta
      skill_as_software_cta
    )

  @doc """
  Expand every `{{name attr="..."}}` shortcode in `body`.

  Unknown names are left verbatim; run `validate/1` first if you want them to
  block a publish instead.
  """
  def expand(body) when is_binary(body) do
    Regex.replace(@shortcode, body, fn full, name, attrs ->
      if name in names(), do: render(name, parse_attrs(attrs)), else: full
    end)
  end

  @doc "Returns `{:ok, []}` or `{:error, unknown_names}`."
  def validate(body) when is_binary(body) do
    unknown =
      @shortcode
      |> Regex.scan(body)
      |> Enum.map(fn [_, name | _] -> name end)
      |> Enum.reject(&(&1 in names()))
      |> Enum.uniq()

    if unknown == [], do: {:ok, []}, else: {:error, unknown}
  end

  defp parse_attrs(attrs) do
    ~r/([a-z_]+)="([^"]*)"/
    |> Regex.scan(attrs)
    |> Map.new(fn [_, k, v] -> {k, v} end)
  end

  @doc "Render one named CTA to an HTML string."
  def render(name, attrs \\ %{}) do
    merged = Map.merge(defaults(name), attrs)

    # Shortcode attributes arrive as string keys; HEEx assigns must be atoms.
    # Only the known keys are converted, so a stray attribute in a post cannot
    # create atoms at runtime.
    assigns =
      for {k, v} <- merged, k in ~w(headline sub body label path campaign), into: %{} do
        {String.to_existing_atom(k), v}
      end

    assigns = Map.merge(%{body: "", label: "Start free"}, assigns)

    rendered =
      assigns
      |> Map.put(:__changed__, nil)
      |> Map.put(:href, href_with_utm(merged))

    case merged["shape"] do
      "aside" -> cta_aside(rendered)
      _ -> cta_card(rendered)
    end
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> flatten_for_earmark()
  end

  # Earmark detects an HTML block by matching an opening tag at the start of a
  # line against a closing tag at the start of a later line. HEEx renders
  # indented multi-line output, and dev builds prepend a debug comment, both of
  # which defeat that match: Earmark warns "Failed to find closing <aside>" and
  # then stops parsing markdown after the block, so the next heading renders as
  # literal text. Collapsing to a single line sidesteps it entirely.
  defp flatten_for_earmark(html) do
    html
    |> String.replace(~r/<!--.*?-->/s, "")
    # Newlines collapse to a single space, not to nothing. HEEx indents
    # interpolated text, so `{@body}\n<a>` is a real word boundary: deleting it
    # outright produced "was.Point the QA agent at your app" in published posts.
    |> String.replace(~r/\s*\R\s*/, " ")
    # Whitespace strictly between two tags carries no meaning, so it goes. This
    # runs second so the step above cannot reintroduce a break Earmark chokes on.
    |> String.replace(~r/>\s+</, "><")
    |> String.trim()
  end

  # The analogy is the default for the non-technical reader because it answers
  # "am I technical enough for this" without arguing, which every longer attempt
  # failed to do.
  defp defaults("nontechnical_founder_cta"),
    do: %{
      "headline" => "If you hired a coder, would you know what to tell them to do?",
      "sub" => "Claude Code is the coder. CodeMySpec is the engineering manager.",
      "label" => "Start free",
      "path" => "/install",
      "campaign" => "nontechnical-founder"
    }

  defp defaults("owned_code_cta"),
    do: %{
      "shape" => "card",
      "headline" => "Your backend should not live on someone else's server.",
      "sub" => "CodeMySpec builds a Phoenix app you own outright.",
      "label" => "Start free",
      "path" => "/install",
      "campaign" => "owned-code"
    }

  # Operator-facing names below. All card shape: a reader who ships an app but
  # does not read the code needs an obvious next step, and reads an understated
  # monospace note as "not for me".
  defp defaults("verified_before_ship_cta"),
    do: %{
      "shape" => "card",
      "headline" => "The agent said the rollback was impossible. It was not.",
      "sub" => "CodeMySpec verifies the running app before it reaches a customer.",
      "label" => "Start free",
      "path" => "/install",
      "campaign" => "verified-before-ship"
    }

  defp defaults("enforced_spec_cta"),
    do: %{
      "shape" => "card",
      "headline" => "A spec nothing enforces is just a nicer prompt.",
      "sub" => "CodeMySpec blocks the build when the code stops matching the spec.",
      "label" => "Start free",
      "path" => "/install",
      "campaign" => "enforced-spec"
    }

  defp defaults("harness_not_model_cta"),
    do: %{
      "shape" => "card",
      "headline" => "Changing only the scaffold moved a benchmark 13.7 points. Same model.",
      "sub" => "The harness is the variable you control. CodeMySpec is the harness.",
      "label" => "Start free",
      "path" => "/install",
      "campaign" => "harness-not-model"
    }

  defp defaults("repo_native_memory_cta"),
    do: %{
      "shape" => "aside",
      "headline" => "Most agent memory is a file somebody wrote by hand.",
      "sub" => "Which is fine, until it stops matching the code.",
      "body" => "CodeMySpec derives context from the repo, so it cannot drift from what is actually there.",
      "label" => "See what repo-derived context looks like",
      "path" => "/install",
      "campaign" => "repo-native-memory"
    }

  defp defaults("skill_as_software_cta"),
    do: %{
      "shape" => "aside",
      "headline" => "A skill is software you are writing for an agent.",
      "sub" => "It deserves the same gates your other software gets.",
      "body" => "CodeMySpec runs specs, tests, and QA over what the agent produces.",
      "label" => "Put gates around your agent",
      "path" => "/install",
      "campaign" => "skill-as-software"
    }

  # Engineer-facing names below. All `:aside`: understated, monospace, inline
  # link rather than a button.
  defp defaults("verification_gate_cta"),
    do: %{
      "shape" => "aside",
      "headline" => "Passing tests are not the same as a working app.",
      "sub" => "A QA agent that opens the app finds what the suite cannot.",
      "body" => "Hook-enforced, so it runs whether or not anyone remembers to.",
      "label" => "Wire it into your repo",
      "path" => "/install",
      "campaign" => "verification-gate"
    }

  defp defaults("enforced_boundary_cta"),
    do: %{
      "shape" => "aside",
      "headline" => "A convention the agent can ignore is a suggestion.",
      "sub" => "A boundary that fails the build is a rule.",
      "body" => "Requirement checkers run over every context an agent touches.",
      "label" => "Set it up on a Phoenix project you already have",
      "path" => "/install",
      "campaign" => "enforced-boundary"
    }

  defp defaults("portable_spec_cta"),
    do: %{
      "shape" => "aside",
      "headline" => "Specs that live in one IDE die with it.",
      "sub" => "These live in your repo and outlive whichever agent you use this month.",
      "body" => "No credit meter, no IDE to adopt.",
      "label" => "Run it against a repo you already have",
      "path" => "/install",
      "campaign" => "portable-spec"
    }

  defp defaults("design_gate_cta"),
    do: %{
      "shape" => "aside",
      "headline" => "Writing one design doc by hand is fine.",
      "sub" => "Writing one per file, and keeping them all true, is not a manual job.",
      "body" => "Enforced rather than documented: no design, no code.",
      "label" => "Generate them from the repo you already have",
      "path" => "/install",
      "campaign" => "design-gate"
    }

  defp defaults("build_speed_cta"),
    do: %{
      "shape" => "aside",
      "headline" => "Shipping fast is only worth it if something checks the result.",
      "sub" => "Both numbers matter, the speed and the issue count.",
      "body" => "Same loop, on your project.",
      "label" => "Run it on your project",
      "path" => "/install",
      "campaign" => "build-speed"
    }

  defp href_with_utm(%{"path" => path, "campaign" => campaign}) do
    sep = if String.contains?(path, "?"), do: "&", else: "?"
    "#{path}#{sep}utm_source=blog&utm_medium=inline&utm_campaign=#{campaign}"
  end

  # `not-prose` keeps the post's typography styles off the button. The outer
  # element is an `<aside>`, never a `<div>`, so Earmark does not drop a closing
  # tag when this lands inside a markdown body.
  defp cta_card(assigns) do
    ~H"""
    <aside class="not-prose card bg-base-200 border border-base-300 my-10">
      <div class="card-body p-5">
        <p class="flex flex-wrap items-center gap-4">
          <span class="flex-1">
            <span class="text-xl font-bold text-base-content">{@headline}</span><br />
            <span class="text-base-content/70">{@sub}</span>
          </span>
          <a href={@href} class="btn btn-primary shrink-0" data-event-label={"cta-inline-#{@campaign}"}>
            {@label}
          </a>
        </p>
      </div>
    </aside>
    """
  end

  # Engineers read a button mid-post as an ad. This is the same offer as a note
  # in the author's voice: a left rule, monospace, and a plain inline link.
  defp cta_aside(assigns) do
    ~H"""
    <aside class="not-prose my-12 max-w-[64ch] font-mono text-[14px] leading-relaxed">
      <div class="border-l-2 border-primary/40 pl-5">
        <p class="text-base-content/90">{@headline}<br />{@sub}</p>
        <p class="mt-3 text-base-content/70">
          {@body}
          <a
            href={@href}
            class="text-base-content underline decoration-primary/60 underline-offset-4 hover:text-primary"
            data-event-label={"cta-inline-#{@campaign}"}
          >{@label}</a>.
        </p>
      </div>
    </aside>
    """
  end
end
