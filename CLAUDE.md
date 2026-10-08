# CLAUDE.md — Project management Rev growth

You are working on **Project management Rev growth**, a calm, structured project-management workspace (Linear/Asana-style) with kanban boards. Local repo path: `C:\Users\Kenny Chen\Documents\projectmanagementkanban`.

**What it is right now:** a front-end-only, high-fidelity product prototype. It uses plain JavaScript ES modules and CSS, bundled by Vite 6. There is no UI framework, no runtime dependency, no backend and no real auth. All state lives in one in-memory store `S`, persisted to `localStorage` under key `gr8r.v2` and seeded from `src/data/seed.js`. It deploys to Vercel as a static `dist/`.

**Before answering or changing code:**

1. Read `claude/system-landscape.md` for architecture, routes, data model and conventions. Read `claude/status-and-gaps.md` for what is real, what is simulated and what is missing.
2. If the repo has `.10x/` and `CLAUDE.md`, treat them as the source of truth for decisions and phase status. Update them when decisions change.

**Hard conventions. Follow them and never introduce alternatives without an explicit decision:**

- **Rendering:** every page or view is a function `(…) => htmlString`, built from `S`. `render()` in `src/shell/render.js` rebuilds the shell and restores focus, selection and scroll. Do not add React, Vue, lit or a virtual DOM.
- **Interactions:** declare `data-a="actionName"` (click), `data-in` (input), `data-blur`, `data-submit`, `data-key-enter`. Register handlers on the shared tables `A`, `IN`, `KEY`, `DBL`, `BLUR` exported from `src/actions/actions.js`. `src/actions/events.js` does the delegation. No inline `onclick` and no per-element listeners.
- **State changes** go through `mutate(fn)` (`src/ui/toast.js`), which handles the offline guard, `save()` and `render()`. Task edits go through `updateTask`/`applyPatch`/`createTask`, so activity logging (`logAct`) and motion flags (`fxSet`) stay consistent.
- **Layering:** dependencies point downward. `core/` and `data/` sit at the bottom, then `ui/ shell/ components/ pages/ views/ overlays/ features/` (render only), then `actions/` (mutate and re-render). A new module must also be imported in `src/main.js` in dependency order, with action modules after `actions/actions.js`.
- **Escaping:** HTML is built with template strings, so wrap every user-controlled string in `esc()` from `core/utils.js`.
- **Icons:** `ic('lucide-name', size)`. The `virtual:icons` Vite plugin bundles only the names quoted in `src/`.
- **Dropdowns:** a plain `<select class="select">`, which `ui/select.js` enhances.
- **Layout:** page edges use `var(--gutter)`. Colours, spacing, type and radius come from `src/styles/tokens.css`. Theme, accent, density and motion are driven by `data-*` attributes on `<html>` (`core/theme.js`).
- **Accessibility:** keep things keyboard-reachable (`makeFocusable`). Respect `prefers-reduced-motion` and the `motion` pref. Use `aria-live` regions (`#sr-live`, `#toasts`).
- **Style:** Prettier (printWidth 160, single quotes, trailing commas, `arrowParens: avoid`), ESLint flat config, 2-space indent, LF line endings, Node 22 (`.nvmrc`).
- CI (`.github/workflows/ci.yml`) runs `npm ci → lint → format:check → build`. Every change must pass all four.

**How to work:** use the 10x-Team flow. Brainstorm, then strategy, design (with an ADR in `.10x/adrs/`), planning, implementation, verification and delivery. Scale the depth to the task. For a request that implies a backend, real auth, multi-user sync or a framework migration, treat it as an architectural change: brainstorm and write an ADR first. Keep answers concrete: name the exact files and functions to touch.

## Where the context lives

- `.10x/status.md`: current phase, blockers, open questions
- `.10x/handoff.md`: context for whichever role picks up next
- `.10x/decisions/<role>/_index.md`: discovered decisions per role (tagged [DISCOVERED] until the owner confirms them)
- `.10x/adrs/`: architecture decision records (required before any architectural change)
- Full landscape: the Claude project docs `claude/system-landscape.md` and `claude/status-and-gaps.md`

## Commands

```bash
npm install && npm run dev      # http://localhost:5173
npm run lint && npm run format:check && npm run build   # same as CI
```
