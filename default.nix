# The schema, flattened to the dotted paths a query uses, as one store path.

# `builtins.toFile` writes at evaluation time, so there is no derivation and
# nothing to build. The compiler reads this path directly.

let
  schema = import ./schema.nix;

  isField = v: builtins.isAttrs v && v ? type;

  flatten = prefix: attrs:
    builtins.concatMap
      (name:
        let
          v = attrs.${name};
          path = if prefix == "" then name else "${prefix}.${name}";
        in
        if isField v
        then [ (v // { inherit path; }) ]
        else if builtins.isAttrs v then flatten path v
        else [ ]
      )
      (builtins.attrNames attrs);

  fields = flatten "" schema;
in
{
  inherit fields;
  count = builtins.length fields;
  file = builtins.toFile "datapunt-schema.json" (builtins.toJSON { inherit fields; });
}
