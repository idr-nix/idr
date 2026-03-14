def main [input: path] {
  open $input | each {|entry|
    let attributes = $entry | reject dn | transpose name values
    [{name: dn, values: $entry.dn}] | append $attributes | each {|attribute|
      [$attribute.values] | flatten | each {|value|
        $"($attribute.name):: ($value | encode base64)"
      } | str join "\n"
    } | where {|line| $line != ""} | str join "\n"
  } | str join "\n\n" | print
}
