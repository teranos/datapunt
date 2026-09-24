# The test workflow. .github/workflows/test.yml is emitted from this and is
# never edited by hand:

#   nix eval --json --file ci/test.nix | nix shell --inputs-from . nixpkgs#jq -c jq . > .github/workflows/test.yml

# JSON is YAML, so GitHub reads the emitted file as it is.

# The core checks itself: the schema vets with no company's kind, and the
# plugin and the CLI test and build against the fixture kind in testdata. The
# release is not here; QNTX's plugin-datapunt workflow builds what ships.
let
  # cue, ldc, dub and jq all come from the nixpkgs this repo's flake.lock pins,
  # as wind's cue does.
  inShell = pkgs: cmd: "nix shell --inputs-from . ${pkgs} -c ${cmd}";
  dub = inShell "nixpkgs#ldc nixpkgs#dub";
in
{
  name = "test";

  on = {
    push.branches = [ "main" ];
    pull_request = null;
  };

  jobs.test = {
    runs-on = "ubuntu-latest";
    env.DATAPUNT_SCHEMAS = "testdata/competitor.cue";
    steps = [
      { uses = "actions/checkout@v5"; }
      { uses = "cachix/install-nix-action@v31.11.1"; }

      # What runs is what this file says: the emitted workflow, emitted again,
      # is the one committed.
      {
        name = "The workflow is what ci/test.nix emits";
        run = ''
          nix eval --json --file ci/test.nix | ${inShell "nixpkgs#jq" "jq ."} | diff - .github/workflows/test.yml
        '';
      }

      {
        name = "The core, with no kind";
        run = "DATAPUNT_SCHEMAS= ./wind";
      }

      {
        name = "Test";
        run = ''
          ${dub "dub test --config=plugin --compiler=ldc2"}
          ${dub "dub test --config=cli --compiler=ldc2"}
        '';
      }

      {
        name = "Build";
        run = ''
          ${dub "dub build --config=plugin --compiler=ldc2 --build=release"}
          ${dub "dub build --config=cli --compiler=ldc2"}
        '';
      }
    ];
  };
}
