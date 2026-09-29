# Retain only options declared by this source before constructing doc records.
# An option from another source may still contain suboptions owned by this one.
{
  lib,
  source,
  options,
}: let
  sourcePrefix = "${source}/";
  declaredHere = option:
    lib.any (file: lib.hasPrefix sourcePrefix (toString file)) option.declarations;
  childrenVisible = option: let
    visible = option.visible or true;
  in
    if builtins.isBool visible
    then visible
    else visible == "transparent";
  filterOptions = attrs:
    lib.mapAttrs (_: value:
      if !lib.isOption value
      then filterOptions value
      else if declaredHere value
      then
        value
        // {
          type =
            value.type
            // {
              getSubOptions = optionPath: filterOptions (value.type.getSubOptions optionPath);
            };
        }
      else if childrenVisible value
      then filterOptions (value.type.getSubOptions value.loc)
      else {})
    attrs;
in
  filterOptions options
