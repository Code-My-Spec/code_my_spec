# Design UI Workflow

The `design_ui` task interviews the engineer to establish the project's
design system. The deliverable is a self-contained HTML file at
`.code_my_spec/design/design_system.html` using the DaisyUI CDN with a
theme switcher — both documentation and live preview in one artifact.

The agent walks the user through five sections one at a time, modifying
an HTML template (provided in the prompt) as choices are made. **Do
not generate HTML from scratch** — always modify the template.

## Required reading

- `priv/knowledge/ui/daisyui.md` — DaisyUI components, theme system,
  semantic colors.
- `priv/knowledge/ui/tailwind.md` — Tailwind utility patterns, layout,
  responsive breakpoints.

## Interview procedure — concrete options, not open-ended questions

At each step, show concrete options and examples. Don't ask "what
colors do you want?" — show palettes and let the user pick.

### 1. Theme

Present DaisyUI built-in themes by name: `corporate`, `nord`,
`dracula`, `winter`, `cupcake`, `emerald`, `cyberpunk`, `valentine`,
`garden`, `lofi`, `pastel`, `wireframe`, `luxury`, `night`, `coffee`,
`dim`, `sunset`.

Ask the user to pick a base theme or go custom. If custom, define CSS
variables under `[data-theme="my-brand"]` with oklch color values.

### 2. Colors

- Custom theme: walk through primary / secondary / accent / neutral
  roles with oklch values.
- Built-in theme: confirm the palette works or adjust individual roles.

Show color swatches in the HTML as you go.

### 3. Typography

Ask about heading scale, content density, and font preferences.

- Scale options: compact (1.125), default (1.25), spacious (1.333).
- Font options: system fonts, Inter, or custom.

### 4. Layout

Ask about:

- Navigation pattern: sidebar / top nav / hybrid.
- Content width: narrow / medium / wide.
- Page templates needed: list, form, detail, dashboard.

### 5. Tone

Visual personality:

- Density: minimal vs information-dense.
- Corners: `rounded-lg` vs `rounded-sm` vs sharp.
- Shadows: none, subtle, pronounced.
- Overall feel: professional, playful, technical.

## After each section

Update the HTML template file with the user's choices. Write the file
back to `.code_my_spec/design/design_system.html` so the user can
preview the result live (open in a browser).

## Done signal — HTML validation

Stop the session once the design system file exists and validates.
The evaluator parses the HTML and checks:

- The `<html>` element has a non-empty `data-theme` attribute.
- Required sections exist as `<section id="theme">`, `<section id="colors">`,
  `<section id="typography">`, `<section id="layout">`, `<section id="tone">`.
- Each required section has content beyond its heading.

Empty section bodies fail. The interview is the path to non-empty
sections — don't skip steps to land the file faster.
