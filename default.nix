# Every declared field, as the kind it belongs to and the dotted path a query
# uses, in one store path.

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

  declared = kind: builtins.removeAttrs schema.${kind} [ "identity" ];

  fields = builtins.concatMap
    (kind: map (f: f // { inherit kind; }) (flatten "" (declared kind)))
    (builtins.attrNames schema);

  kinds = map
    (kind: { name = kind; identity = schema.${kind}.identity; })
    (builtins.attrNames schema);
in
{
  inherit fields kinds;
  count = builtins.length fields;
  file = builtins.toFile "datapunt-schema.json" (builtins.toJSON { inherit fields kinds; });
}
