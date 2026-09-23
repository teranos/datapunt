# The release workflow. .github/workflows/release.yml is emitted from this and
# is never edited by hand:

#   nix eval --json --file ci/release.nix | jq . > .github/workflows/release.yml

# JSON is YAML, so GitHub reads the emitted file as it is.

# datapunt is a QNTX plugin: `dub build --config=plugin`. The node fetches it
# by this repo's URL in [plugin] enabled, and takes the newest release carrying
# the plugin's asset.

# The version is PLUGIN_VERSION in src/plugin/service.d, asked of the binary it
# was built into, and the tag is made from it here rather than typed.
let
  version = "\${{ steps.version.outputs.version }}";
  artifact = "\${{ steps.package.outputs.artifact }}";

  # q-box has no gh. This one is the nixpkgs this repo's flake.lock pins.
  gh = ''gh() { nix shell --inputs-from "$GITHUB_WORKSPACE" nixpkgs#gh -c gh "$@"; }'';
in
{
  name = "release";

  on = {
    push = {
      branches = [ "main" ];
      paths = [
        "src/**"
        "schema.nix"
        "default.nix"
        "wind"
        "dub.json"
        ".github/workflows/release.yml"
      ];
    };
    workflow_dispatch = null;
  };

  permissions.contents = "write";

  # q-box, where the plugin runs, so it is built against the glibc it runs on.
  jobs.linux-amd64 = {
    runs-on = [ "self-hosted" "q-box" ];
    steps = [
      { uses = "actions/checkout@v5"; }

      # Nix only evaluates the schema into .ctfe/schema.json (wind).
      { uses = "cachix/install-nix-action@v31.11.1"; }

      {
        uses = "dlang-community/setup-dlang@v2.0.0";
        "with".compiler = "ldc-1.41.0";
      }

      {
        name = "Test";
        run = "dub test --config=plugin --compiler=ldc2";
      }

      {
        name = "Build plugin";
        run = "dub build --config=plugin --compiler=ldc2 --build=release";
      }

      # A version already released is not released again. Read off the release
      # tags, so a gh that fails stops here instead of reading as not released.
      {
        name = "Resolve version";
        id = "version";
        env.GH_TOKEN = "\${{ github.token }}";
        env.GH_REPO = "\${{ github.repository }}";
        run = ''
          ${gh}
          VERSION=$(./bin/qntx-datapunt-plugin --version | cut -d' ' -f2)
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          TAGS=$(gh release list --limit 1000 --json tagName --jq '.[].tagName')
          FRESH=yes
          for TAG in $TAGS; do
            if [ "$TAG" = "datapunt-v$VERSION" ]; then FRESH=no; fi
          done
          if [ "$FRESH" = no ]; then
            echo "datapunt-v$VERSION is already released — change the schema or bump PLUGIN_VERSION in src/plugin/service.d to ship again" >&2
          fi
          echo "fresh=$FRESH" >> "$GITHUB_OUTPUT"
        '';
      }

      # Both names are the fetcher's: the asset ends in -<GOOS>-<GOARCH>.tar.gz,
      # and the binary inside is qntx-<name>-plugin.
      {
        name = "Package";
        id = "package";
        run = ''
          ARTIFACT="qntx-datapunt-plugin-${version}-linux-amd64.tar.gz"
          tar -czf "$ARTIFACT" -C bin qntx-datapunt-plugin
          sha256sum "$ARTIFACT" > "$ARTIFACT.sha256"
          echo "artifact=$ARTIFACT" >> "$GITHUB_OUTPUT"
        '';
      }

      # What ships is what is unpacked, run on the machine it runs on.
      {
        name = "Verify the artifact runs";
        run = ''
          VERIFY="$RUNNER_TEMP/verify-datapunt"
          rm -rf "$VERIFY" && mkdir -p "$VERIFY"
          tar -xzf "${artifact}" -C "$VERIFY"
          "$VERIFY/qntx-datapunt-plugin" --version
        '';
      }

      {
        name = "Upload artifact";
        "if" = "steps.version.outputs.fresh != 'yes'";
        uses = "actions/upload-artifact@v4";
        "with" = {
          name = artifact;
          path = ''
            ${artifact}
            ${artifact}.sha256
          '';
        };
      }

      {
        name = "Publish release";
        "if" = "steps.version.outputs.fresh == 'yes'";
        env.GH_TOKEN = "\${{ github.token }}";
        env.GH_REPO = "\${{ github.repository }}";
        run = ''
          ${gh}
          TAG="datapunt-v${version}"
          gh release create "$TAG" \
            "${artifact}" \
            "${artifact}.sha256" \
            --target "$GITHUB_SHA" --title "$TAG" --generate-notes
        '';
      }
    ];
  };
}
