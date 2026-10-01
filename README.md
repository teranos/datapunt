# datapunt

A schema compiled into a QNTX plugin. What a subject may carry is
declared once, in CUE, and the binary refuses anything else; the observations
live in QNTX, one namespace per company, and the node hands each call the
store of the caller's namespace without naming it (QNTX ADR-038).

This repo is the core: the plugin, `schema/datapunt.cue` with the definitions
and the idiom. Other repos add fields to `schema` in
their own files of package `datapunt`, and `wind` unifies those files.

`wind` is the check and the export: `DATAPUNT_SCHEMAS` names the company
files, and `dub build --config=plugin` runs it first.

The core tests itself against `testdata/competitor.cue`, a test fixture:

    DATAPUNT_SCHEMAS=testdata/competitor.cue dub test --config=plugin

CI runs that, vets the core alone, and builds the plugin.
`.github/workflows/test.yml` is emitted from `ci/test.nix`, never edited by
hand, and CI fails when the two differ.

## Decided

2026-10-01:

"Im only interested in Datapunt as the Plugin"


Brandon, 2026-09-23, on why the schema moves from Nix to CUE:

"the reason for CUE is that i want to use datapunt for multiple namespaces
and copanies to do datapunt work for"

"the datapunt as a qntx plugin build should happen in qntx"

"and the datapunt repo becomes an agnostic core"

## Open

- [ ] Automate datapunt analysis of competitors, beyond Clean, as stoke
      handlers on QNTX.
