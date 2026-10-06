_: _: {
  defaults = {
    programs.git = {
      enable = true;
      config.user = {
        name = "Operator";
        email = "operator@example.invalid";
      };
    };
    users = {
      users.operator = {
        isNormalUser = true;
        uid = 1000;
        group = "operator";
      };
      groups.operator.gid = 1000;
    };
  };
}
