# Document each set of suboptions once. An option whose suboptions are declared
# where an enclosing option's are, as a nested service repeats its parent, is
# listed without them; following them would never end.
{
  lib,
  options,
}: let
  signature = subOptions:
    map (option: option.declarationPositions or option.declarations)
    (lib.collect lib.isOption subOptions);
  guard = ancestors:
    lib.mapAttrs (_: value:
      if !lib.isOption value
      then guard ancestors value
      else
        value
        // {
          type =
            value.type
            // {
              getSubOptions = path: let
                subOptions = value.type.getSubOptions path;
                own = signature subOptions;
              in
                if own != [] && lib.elem own ancestors
                then {}
                else guard (ancestors ++ [own]) subOptions;
            };
        });
in
  guard [] options
