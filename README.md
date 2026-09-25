# datapunt

A schema compiled into a QNTX plugin. What a subject of a kind may carry is
declared once, in CUE, and the binary refuses anything else; the observations
live in QNTX, one namespace per company, and the node hands each call the
store of the caller's namespace without naming it (QNTX ADR-038).

This repo is the core: the plugin, `schema/datapunt.cue` with the definitions
and the idiom, and no kind of its own. A company keeps its kinds in its own
repo as one CUE file in package `datapunt`, and the build that unifies the
core with every company's file and releases the plugin is QNTX's
`plugin-datapunt` workflow, called by the deployment that runs the node.

`wind` is the check and the export: `DATAPUNT_SCHEMAS` names the company
files, and `dub build --config=plugin` runs it first.

## Decided

Brandon, 2026-09-23, on why the schema moves from Nix to CUE:

"the reason for CUE is that i want to use datapunt for multiple namespaces
and copanies to do datapunt work for"

"the datapunt as a qntx plugin build should happen in qntx"

"and the datapunt repo becomes an agnostic core"

Brandon, 2026-09-25, on datapunt's color:

"Let's say we adopt their note element beige as base"

The base is `#f5edb8`, the background of QNTX's note element
(`web/ts/components/element/note-element.ts` there). The note element pairs
it with ink `#2a2a2a`, edge `#d4c59a` and muted `#8a7a5a`.

## Open

- [ ] Automate datapunt analysis of competitors, beyond Clean, as stoke
      handlers on QNTX.
- [ ] Put the base to use. The plugin draws nothing yet: it registers no
      canvas element, and QNTX's plugin metadata has no field for a color.
