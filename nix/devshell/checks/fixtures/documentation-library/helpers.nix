{
  /**
  Return a greeting for the named project operator.

  # Example

  ```nix
  lib.greet "Robin"
  => "Hello Robin"
  ```

  # Type

  ```
  greet :: String -> String
  ```

  # Arguments

  name
  : The operator's display name.
  */
  greet = name: "Hello ${name}";
}
