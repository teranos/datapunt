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

The core tests itself against `testdata/competitor.cue`, a fixture kind that
datapunt does not ship:

    DATAPUNT_SCHEMAS=testdata/competitor.cue dub test --config=plugin

CI runs that and the CLI's tests, vets the core with no kind at all, and
builds both configurations. `.github/workflows/test.yml` is emitted from
`ci/test.nix`, never edited by hand, and CI fails when the two differ.

## Trying it against a real node

`datapunt:test` is the predicate for trying datapunt out against a real node:
observations about subjects that are not real, written where a real namespace
can hold them without anyone reading them as findings. With `DATAPUNT_TEST=1`
the CLI reads and writes `datapunt:test` instead of `datapunt:observed`, and
every read names its predicate, so neither lane sees the other:

    DATAPUNT_SCHEMAS=testdata/competitor.cue dub build --config=cli
    DATAPUNT_TEST=1 ./datapunt competitor datapunt-test.example cta.phone "020 000 0000"
    DATAPUNT_TEST=1 ./datapunt competitor

Name a subject that is plainly not real, such as `datapunt-test.example`: a
build from before reads named their predicate reads every predicate, and would
take a test statement about a real subject as that subject's newest record.

## Decided

Brandon, 2026-09-23, on why the schema moves from Nix to CUE:

"the reason for CUE is that i want to use datapunt for multiple namespaces
and copanies to do datapunt work for"

"the datapunt as a qntx plugin build should happen in qntx"

"and the datapunt repo becomes an agnostic core"

## Open

- [ ] Automate datapunt analysis of competitors, beyond Clean, as stoke
      handlers on QNTX.
