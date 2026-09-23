{
  description = "datapunt: a schema compiled into a QNTX plugin";

  # The one nixpkgs the release takes gh from (ci/release.nix), pinned by rev.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/50ab793786d9de88ee30ec4e4c24fb4236fc2674";

  outputs = { self, nixpkgs }: { };
}
